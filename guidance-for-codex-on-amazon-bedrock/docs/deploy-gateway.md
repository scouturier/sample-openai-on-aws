# Deploy — Gateway (Alternative)

Stand an OpenAI-compatible proxy in front of Bedrock. Developers point Codex at
the gateway with a per-user API key; the gateway authenticates to Bedrock with
its ECS task role. Use this path when you need hard per-user budgets,
multi-provider fan-out, or a single enforcement point that is not tied to AWS
identity.

If you only need per-user *attribution* and already run IdC, prefer
`deploy-identity-center.md` — it is simpler and cheaper.

Measured time-to-first-successful-Bedrock-call using the LiteLLM reference
implementation: ~886s end-to-end from a clean account (2026-05-08), dominated
by the 885s ECS+RDS stack create. Per-call latency once running: ~535ms.

## The pattern

```
Developer (Codex CLI)
    │  Authorization: Bearer <per-user-key-or-JWT>
    ▼
ALB (HTTPS, WAF / OIDC / JWT validation)
    ▼
Gateway (ECS Fargate task)           ── OTel ──▶  OTel collector ──▶ CloudWatch
    │   auth to Bedrock via task role
    ▼
Amazon Bedrock (Converse / InvokeModel)
```

Two auth hops: **developer → gateway** (JWT or per-user API key) and
**gateway → Bedrock** (ECS task IAM role). No AWS credentials reach developer
machines; there is no binary to sign, notarize, or distribute.

## What to look for in a gateway

A production-grade gateway for this use case needs to cover all of:

- **Per-user identity on every request.** JWT validation at the ALB or in the
  gateway, or a master key that mints per-user API keys. You need something
  stable to attribute cost and enforce quota against.
- **Hard per-user budgets with automatic cutoff.** Not just alerts — a 429 when
  a user hits the limit. This is the headline reason to run a gateway at all.
- **Multi-provider routing.** Bedrock today; Bedrock + OpenAI direct + Anthropic
  direct tomorrow. Gateways earn their keep once you have more than one
  upstream.
- **OTel emission on success *and* failure.** Every call should produce a span
  or metric with the user-id dimension. Confirm the gateway actually emits
  failure events before relying on alarms.
- **Signed, auditable distribution of client config.** What you give developers
  is a URL plus a per-user secret — so secret rotation, revocation, and
  bootstrap need a story. Don't email keys.
- **GovCloud posture.** If you need FedRAMP: is the gateway image available in
  GovCloud ECR mirrors, does the auth stack work without the commercial IdC
  control plane, and can the OTel pipeline write to GovCloud CloudWatch.

If a candidate ticks all six, it will work here. The reference below uses
LiteLLM, but the structure is the same for every alternative.

## LiteLLM reference implementation

What ships in this repo under `deployment/litellm/`. Use it as-is or as a
blueprint for a different gateway.

### Prerequisites

- AWS account with IAM, ECS, RDS, ECR, and Bedrock access.
- Bedrock activated in the target region (today: `us-west-2` for GPT-5.4).
- Docker (local) + AWS CLI v2 (control host).
- The OTel networking + collector stacks already deployed — the gateway reuses
  their VPC and collector endpoint. Stand them up first with:

  ```bash
  deployment/scripts/deploy-otel-stack.sh --region us-west-2
  ```

### 1. Build and push the LiteLLM image

The config is baked into the image so the running task has no external config
fetch. If you need to change models or callbacks, rebuild and redeploy.

```bash
REGION=us-west-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/codex-litellm

aws ecr create-repository --repository-name codex-litellm --region $REGION
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin $ECR_URI

docker build -t $ECR_URI:latest deployment/litellm
docker push $ECR_URI:latest
```

### 2. Deploy the gateway stack

```bash
aws cloudformation deploy \
  --stack-name codex-litellm-gateway \
  --template-file deployment/litellm/ecs/litellm-ecs.yaml \
  --capabilities CAPABILITY_IAM \
  --region $REGION \
  --parameter-overrides \
    NetworkingStackName=codex-otel-networking \
    OtelStackName=codex-otel-collector \
    AwsRegion=$REGION \
    LiteLLMImage=$ECR_URI:latest \
    LiteLLMMasterKey=sk-$(openssl rand -hex 16) \
    DBPassword=$(openssl rand -hex 16) \
    AllowedCidr=10.0.0.0/16
```

Notes on the parameter defaults (hardening TODOs):

- `AwsRegion` defaults to `us-east-1`; **always override** it to the region
  where Bedrock is actually enabled.
- `AllowedCidr` defaults to `10.0.0.0/16` (VPC-internal). For E2E testing from
  outside the VPC, add a temporary `/32` ingress rule on the ALB security
  group; remove it after.
- The template's `litellm_config.yaml` ships a `bedrock/openai.gpt-5.4`
  placeholder that does not resolve today. The `gpt-oss-120b` alias works end
  to end; `gpt-5.4` is re-verified at launch.

### 3. Verify the gateway is reachable

```bash
GATEWAY=$(aws cloudformation describe-stacks \
  --stack-name codex-litellm-gateway --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='GatewayEndpoint'].OutputValue" \
  --output text)

curl -s "$GATEWAY/health/liveness" -H "Authorization: Bearer $MASTER_KEY"
```

### 4. Mint per-user keys

```bash
curl -sX POST "$GATEWAY/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"alice@example.com","max_budget":50,"budget_duration":"30d"}'
```

For self-service SSO-minted keys (LiteLLM Enterprise), configure
`GENERIC_CLIENT_ID` / `GENERIC_AUTHORIZATION_ENDPOINT` / `PROXY_BASE_URL` on
the task and direct users to `$GATEWAY/sso/key/generate`.

### 5. Configure Codex to route through the gateway

```toml
# ~/.codex/config.toml
model_provider = "openai"

[openai]
base_url = "https://<gateway-alb-dns>/v1"
api_key  = "sk-<user-key>"
```

Test:

```bash
curl -s "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer sk-<user-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-oss-120b","messages":[{"role":"user","content":"OK?"}]}'
```

### 6. Confirm OTel traces land in CloudWatch

LiteLLM's `callbacks: ["otel"]` emits spans to the collector ALB on every
call. In the OTel collector log group (`/ecs/otel-collector`), search for
`otelcol.signal=traces` — 8 spans per call round-trip from the 2026-05-08 run.

### Local iteration

Use `docker compose up` under `deployment/litellm/` to bring up LiteLLM +
Postgres + a debug OTel collector on localhost:4000. The compose file uses
the host EC2/Mac AWS credentials, so `aws configure` or an SSO profile is
required; there is no static AWS key material in the image or compose.

### Teardown

RDS has `DeletionProtection: true` — disable it before deleting the stack,
otherwise `delete-stack` fails halfway:

```bash
DB_ID=$(aws cloudformation describe-stack-resources \
  --stack-name codex-litellm-gateway --region $REGION \
  --query "StackResources[?LogicalResourceId=='RDSInstance'].PhysicalResourceId" \
  --output text)

aws rds modify-db-instance \
  --db-instance-identifier $DB_ID \
  --no-deletion-protection --apply-immediately --region $REGION

aws cloudformation delete-stack \
  --stack-name codex-litellm-gateway --region $REGION

aws ecr delete-repository \
  --repository-name codex-litellm --force --region $REGION
```

## Also consider

All of these cover the pattern above; pick by what your org already operates.

| Gateway | One-line tradeoff |
|---|---|
| **Portkey** | Hosted or self-hosted; strongest guardrails + prompt caching story; adds a vendor dependency. |
| **Kong AI Gateway** | Best if you already run Kong for non-AI traffic — reuses existing auth, rate-limit, and OTel plumbing. |
| **Helicone** | Lightweight proxy focused on observability; weaker on budget enforcement and JWT auth than LiteLLM/Portkey. |
| **AWS Bedrock Gateway sample** | AWS-owned reference implementation; minimal surface, but no built-in per-user budgets — you wire them yourself. |
| **Custom FastAPI shim** | Fine if your needs are small and you already own the operational muscle; rebuild budgets, OTel, and SSO from scratch. |

## Known gotchas

- **Cost floor.** ALB + RDS + ECS Fargate is ~$80–120/mo even idle. The
  IdC path has no comparable standing cost.
- **RDS deletion protection.** Default-on; tear-down requires the
  `modify-db-instance` step above.
- **Region mismatch footgun.** Template default `AwsRegion=us-east-1`;
  override it on every deploy.
- **`gpt-5.4` model alias.** Shipped in `litellm_config.yaml` as a
  placeholder; verify it resolves when GPT-5.4 launches.
- **Full Codex-client leg not yet re-run.** The 2026-05-08 E2E verified the
  gateway's OpenAI wire format via `curl`; the `codex` binary against the
  gateway is re-run at the GPT-5.4 pre-flight.
