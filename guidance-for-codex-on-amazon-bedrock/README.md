# Guidance for Codex on Amazon Bedrock

Enterprise deployment patterns for [Codex](https://openai.com/codex) running
against [Amazon Bedrock](https://aws.amazon.com/bedrock/) (OpenAI models:
`openai.gpt-5.4`, `openai.gpt-oss-*`). Two patterns, in recommended order:
pick the first your org can actually run.

> **Decision rule:** If you can run IAM Identity Center, use IAM Identity
> Center. If you can't and you need centralized enforcement or multi-provider
> fan-out, run the Gateway.

## Deployment paths

| | **IAM Identity Center** (recommended) | **Gateway** (alternative) |
|---|---|---|
| Developer setup | `aws sso login` via AWS CLI v2 | OIDC JWT + `OPENAI_BASE_URL` |
| Binary distribution | Signed AWS CLI v2 (winget/MSI/brew/MDM) | None |
| Infra to run | None (free AWS control plane) | ECS Fargate + ALB + Postgres |
| Bedrock auth | Per-user federated IAM | Gateway IAM task role |
| Per-user attribution | CloudTrail `userIdentity` | JWT claims via OTel |
| Hard per-user budgets | No | Yes |
| Codex provider | Native `amazon-bedrock` | Generic `openai` |

Full comparison + prereq checklists: **[docs/01-decide.md](docs/01-decide.md)**.

## Identity chain

The invariant every path preserves: the SSO user identity flows end-to-end.

```
Corporate IdP  ──(SAML+SCIM)──▶  AWS IAM Identity Center
                                        │
                                        ▼
                         AWSReservedSSO_CodexBedrockUser_* session
                                        │
                                        ▼
                           Bedrock customer-managed policy
                                        │
                   ┌────────────────────┼────────────────────┐
                   ▼                    ▼                    ▼
           CloudTrail            Bedrock Converse     CloudWatch (OTel)
        userIdentity = UPN      (native SigV4 path)   user.id = UPN header
                   │
                   ▼
              CUR (cost)
```

## Start here

1. **[Decide](docs/01-decide.md)** — three-path comparison; pick your path in
   ≤10 minutes.
2. **Deploy** — one canonical doc per path.
   - [IAM Identity Center](docs/deploy-identity-center.md) — **ready**.
   - [Gateway](docs/deploy-gateway.md) — **ready**.
3. **Operate**
   - [Monitoring + cost attribution](docs/operate-monitoring.md)
   - [Troubleshooting](docs/operate-troubleshooting.md)
   - [Region / model matrix](docs/reference-regions.md)

## The short version (IAM Identity Center)

### Admin

```bash
# 1. Deploy the Bedrock auth stack
aws cloudformation deploy \
  --stack-name codex-bedrock-idc \
  --template-file deployment/infrastructure/bedrock-auth-idc.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2

# 2. Create a CodexBedrockUser permission set in IdC; attach the
#    customer-managed policy from the stack; assign to your Codex group.

# 3. Generate the developer bundle
deployment/scripts/generate-codex-sso-config.sh \
  --start-url https://d-xxxxxxxxxx.awsapps.com/start \
  --sso-region us-east-1 \
  --account-id 123456789012 \
  --permission-set CodexBedrockUser \
  --bedrock-region us-west-2 \
  --profile-name codex \
  --outdir ./dist/codex-sso
```

Distribute `./dist/codex-sso/` (zip + S3 presigned URL, MDM payload, etc.).

### Developer

```bash
./install.sh                      # writes fenced managed blocks to
                                  # ~/.aws/config and ~/.codex/config.toml
aws sso login --profile codex
codex                             # native amazon-bedrock provider
```

See **[deploy-identity-center.md](docs/deploy-identity-center.md)** for the
full walkthrough (validation, CloudTrail attribution, optional OTel, teardown).

## What's in this repo

```
guidance-for-codex-on-amazon-bedrock/
├── README.md                              ← you are here
├── docs/
│   ├── 01-decide.md                       ← two-path comparison + prereqs
│   ├── deploy-identity-center.md          ← canonical IdC deployment
│   ├── deploy-gateway.md                  ← canonical Gateway deployment
│   ├── operate-monitoring.md              ← monitoring + cost attribution
│   ├── operate-troubleshooting.md         ← cross-path failure modes
│   └── reference-regions.md               ← region / model matrix
├── deployment/
│   ├── infrastructure/
│   │   ├── bedrock-auth-idc.yaml          ← IdC Bedrock policy + role
│   │   ├── networking.yaml                ← VPC for optional OTel stack
│   │   ├── otel-collector.yaml            ← ECS Fargate OTel collector
│   │   └── codex-otel-dashboard.yaml      ← CloudWatch usage dashboard
│   ├── litellm/                           ← LiteLLM gateway (alternative)
│   └── scripts/
│       ├── generate-codex-sso-config.sh   ← admin-side distributable generator
│       └── deploy-otel-stack.sh           ← OTel stack one-shot deploy
├── specs/
│   ├── README.md                          ← agent-facing spec (invariants)
│   ├── PLAN.md                            ← progress tracker (authoritative)
│   └── 02-otel-dashboard.md, 03-*        ← working notes, being folded in
└── assets/images/                         ← architecture + dashboard images
```

## Bedrock models

Currently supported (as of 2026-05-08):

| Model ID | Notes |
|---|---|
| `openai.gpt-5.4` | **Recommended default.** Routes through Bedrock Mantle. |
| `openai.gpt-oss-120b` | GPT-OSS 120B (Converse-compatible). |
| `openai.gpt-oss-20b` | GPT-OSS 20B (Converse-compatible). |

OpenAI models on Bedrock are available in US regions (`us-east-1`,
`us-east-2`, `us-west-2`). See `docs/reference-regions.md` for the full
matrix.

## Status

Migration from the prior single-path layout is in progress. IdC path is
end-to-end validated (time-to-first-successful-Bedrock-call: 275s on Mac,
2026-05-08). Gateway path infra + doc are complete. Tracked in
**[specs/PLAN.md](specs/PLAN.md)**.

## License

MIT — see [LICENSE](LICENSE).
