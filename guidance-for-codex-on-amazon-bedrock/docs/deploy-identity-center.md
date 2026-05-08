# Deploy — IAM Identity Center (Recommended)

Federate AWS IAM Identity Center (IdC) from your existing corporate IdP so
developers get AWS credentials backed by their SSO identity. Codex reads the
resulting profile through the standard AWS SDK credential chain.

Measured time-to-first-successful-Bedrock-call: ~275s end-to-end on macOS
(2026-05-08) — mostly the interactive browser sign-in.

## Prerequisites

- **AWS Organizations** enabled (IdC requires Orgs).
- An IdP that can federate to AWS via SAML 2.0 + SCIM 2.0. Supported: EntraID,
  Okta, Ping, JumpCloud, Google Workspace, CyberArk, OneLogin.
- Admin access in both the AWS management account and the corporate IdP.
- AWS CLI v2 distributable to end users via winget / MSI / Homebrew / MDM.
- Bedrock activated in the target region(s). For GPT-5.4 today: `us-west-2`.

## Admin setup (one-time)

### 1. Enable IdC in the AWS management account

Region-pin the IdC instance — it is single-region, though permission sets can
grant access to Bedrock in any region.

### 2. Wire your IdP as the identity source

EntraID and Okta have first-class gallery apps with AWS-published setup guides.
Exchange SAML metadata, then enable SCIM automatic provisioning using the
tenant URL + bearer token IdC generates.

Known SCIM quirks:
- Nested groups from EntraID do **not** flatten — provision leaf groups.
- Attribute mapping for email/username occasionally trips initial setup.

### 3. Deploy the Bedrock auth stack

```bash
aws cloudformation deploy \
  --stack-name codex-bedrock-idc \
  --template-file deployment/infrastructure/bedrock-auth-idc.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

Outputs include the customer-managed policy ARN to attach to the permission
set in the next step.

### 4. Create the `CodexBedrockUser` permission set

Replace `<idc-instance-arn>`, `<account-id>`, `<group-id>`, and the policy name
with your values. Session duration defaults to 8h; raise up to 12h (`PT12H`)
for long Codex sessions.

```bash
IDC_ARN=arn:aws:sso:::instance/ssoins-xxxxxxxxxxxxxxxx
ACCOUNT_ID=123456789012
GROUP_ID=<idc-group-id-for-codex-users>
POLICY_NAME=CodexBedrockPolicy   # from bedrock-auth-idc.yaml output

# Create the permission set
PS_ARN=$(aws sso-admin create-permission-set \
  --instance-arn "$IDC_ARN" \
  --name CodexBedrockUser \
  --session-duration PT8H \
  --query 'PermissionSet.PermissionSetArn' --output text)

# Attach the customer-managed policy from step 3
aws sso-admin attach-customer-managed-policy-reference-to-permission-set \
  --instance-arn "$IDC_ARN" \
  --permission-set-arn "$PS_ARN" \
  --customer-managed-policy-reference "Name=$POLICY_NAME,Path=/"

# Assign the permission set to the Codex user group in the target account
aws sso-admin create-account-assignment \
  --instance-arn "$IDC_ARN" \
  --permission-set-arn "$PS_ARN" \
  --principal-type GROUP --principal-id "$GROUP_ID" \
  --target-type AWS_ACCOUNT --target-id "$ACCOUNT_ID"
```

Console equivalent: IAM Identity Center → Permission sets → Create, then
attach the customer-managed policy by name and assign to the group in each
target account.

### 5. Generate and distribute the developer bundle

```bash
deployment/scripts/generate-codex-sso-config.sh \
  --start-url https://d-xxxxxxxxxx.awsapps.com/start \
  --sso-region us-east-1 \
  --account-id 123456789012 \
  --permission-set CodexBedrockUser \
  --bedrock-region us-west-2 \
  --profile-name codex \
  --model openai.gpt-5.4 \
  --otel-endpoint https://otel.your-org.example/v1/metrics \
  --outdir ./dist/codex-sso
```

`--otel-endpoint` is optional; omit it if you're not running the OTel stack.
The bundle is self-contained — zip `./dist/codex-sso/` and distribute.

## End-user flow

Documented in the bundle's `DEV-SETUP.md`. The short version:

```bash
./install.sh           # writes fenced managed blocks to ~/.aws/config and ~/.codex/config.toml
aws sso login --profile codex
codex                  # AWS_PROFILE is picked up via the [model_providers.amazon-bedrock.aws] block
```

The `codex-sso-creds` helper (installed to `~/.local/bin`) is wired in as the
profile's `credential_process`. It auto-launches `aws sso login` when the
cached SSO token is missing or expired, so users see a browser pop once per
working day and nothing else.

### Headless / remote hosts (no local browser)

`aws sso login` defaults to opening a browser on the same machine. On headless
hosts — bastions, EC2 dev boxes, SSH-only field laptops, CI runners — use the
device-code flow instead:

```bash
aws sso login --profile codex --no-browser
# Prints a verification URL + one-time code.
# Open the URL on any device where you can sign in to your IdP,
# enter the code, approve. Back on the headless host, the command
# returns once the cache is populated.
```

The bundled helper auto-launches plain `aws sso login` on cache miss and will
fail on headless hosts. Pre-warm with `--no-browser` before starting Codex;
re-run when the 8h token expires. Fully non-interactive fleet/CI pre-warm is
tracked in `specs/PLAN.md`.

### Uninstall

`./uninstall.sh` from the bundle strips the fenced blocks from
`~/.aws/config` and `~/.codex/config.toml`, removes the helper, and preserves
timestamped backups.

## Validation

```bash
aws sso login --profile codex
aws sts get-caller-identity --profile codex
# Expect: Arn: arn:aws:sts::<account>:assumed-role/AWSReservedSSO_CodexBedrockUser_.../<sso-user>

aws bedrock-runtime converse \
  --profile codex --region us-west-2 \
  --model-id openai.gpt-oss-120b-1:0 \
  --messages '[{"role":"user","content":[{"text":"OK?"}]}]'
```

If this succeeds, the IdC → Bedrock auth chain is working. The Codex
`amazon-bedrock` provider routes through a mantle endpoint; set the `model`
line in the installed `~/.codex/config.toml` to a mantle-served model to
round-trip from the Codex client — no auth or IAM changes needed.

## CloudTrail attribution

Every `bedrock:InvokeModel` call produces a CloudTrail event where:

- `userIdentity.type` = `AssumedRole`
- `userIdentity.principalId` = `<role-id>:<SSO-username>`
- `userIdentity.sessionContext.sessionIssuer.userName` = permission-set role name
- Session name carries the corporate UPN (per SCIM attribute mapping)

Pair with Bedrock Application Inference Profiles for per-team cost allocation
in CUR.

## Quota & budgets

IdC gives you per-user *attribution*, not enforcement. What you can and can't
do on this path:

| Want | Available | How |
|---|---|---|
| Per-team quota partitioning | Yes | Bedrock **Application Inference Profiles** — grant different IdC groups access to different profile ARNs via the permission set; each profile carries its own quota. |
| Restrict users to specific models / regions / profiles | Yes | IAM policy conditions in the customer-managed policy attached to the permission set. |
| Alert when a user crosses a usage threshold | Yes | CloudWatch alarm on the OTel `user.id` dimension (requires the optional OTel stack below). Alerts only — no cutoff. |
| Hard per-user token / dollar budget with automatic cutoff | **No** | Not achievable with IdC alone. This is the LiteLLM Gateway's job — see `docs/01-decide.md`. |

Bedrock service quotas themselves are account-level (requests/min, tokens/min
per model); they throttle the whole account, not individual users.

## Optional: OTel usage dashboard

Per-user usage attribution in CloudWatch. Order is: **deploy the collector
stack first**, then pass its ALB endpoint into `generate-codex-sso-config.sh`
via `--otel-endpoint` so each distributed `config.toml` has an `[otel]` block
pointing at your collector. The collector
(`deployment/infrastructure/otel-collector.yaml`) extracts the `x-user-id`
header stamped by `install.sh` into a CloudWatch `user.id` dimension.

### 1. Deploy the collector stack

```bash
deployment/scripts/deploy-otel-stack.sh --region us-west-2
```

The script deploys three stacks in order (`codex-otel-networking`,
`codex-otel-collector`, `codex-otel-dashboard`) and prints the ALB endpoint.
Full deploy runs ~5 minutes in a clean account.

Useful flags:

| Flag | Purpose |
|---|---|
| `--region` | Target region (default `us-west-2`). |
| `--stack-prefix` | Rename the three stacks (default `codex-otel`). |
| `--dashboard-name` | CloudWatch dashboard name (default `CodexOnBedrock`). |
| `--input-price` / `--output-price` / `--cached-input-price` | Per-1M-token USD for the dashboard's spend-estimate widgets. Defaults are placeholders — update after GPT-5.4 pricing publishes. |

### 2. Harden the collector (opt-in — recommended before non-sandbox use)

Default posture is HTTP-only: the collector accepts any `x-user-id` value
(trust-on-distribution). For production, pass all five flags below together
to enable HTTPS + ALB JWT validation:

```bash
deployment/scripts/deploy-otel-stack.sh \
  --region us-west-2 \
  --custom-domain otel.codex.example.com \
  --hosted-zone-id Z0123456789ABCDEFGHIJ \
  --oidc-issuer https://cognito-idp.us-west-2.amazonaws.com/<pool-id> \
  --oidc-jwks https://cognito-idp.us-west-2.amazonaws.com/<pool-id>/.well-known/jwks.json \
  --oidc-client-id <app-client-id>
```

With JWT validation on, each developer also needs a bearer token — wire it
into the generator with a static header (see `--otel-endpoint` usage in
step 5 of Admin setup; per-user token distribution is out of scope for this
doc).

Trade-offs between the two postures are in `specs/02-otel-dashboard.md`.

### 3. Wire the endpoint into the developer bundle

Feed the printed ALB endpoint into `generate-codex-sso-config.sh`:

```bash
deployment/scripts/generate-codex-sso-config.sh \
  ... \
  --otel-endpoint https://otel.codex.example.com/v1/metrics
```

`install.sh` in the bundle resolves the end-user's SSO identity at install
time and bakes it into the `[otel]` block as a static `x-user-id` header;
every metric carries that dimension.

See `specs/PLAN.md` for current validation status of the Codex-client metrics
round-trip.

## Known gotchas

- **Session duration.** 8h default can interrupt long Codex runs; raise up to
  12h on the permission set, or accept `aws sso login` re-auth as UX.
- **GovCloud.** IdC works in GovCloud but must be enabled separately; FedRAMP
  parity is an open question (`specs/PLAN.md`).
- **Single-region IdC.** Control plane is regional; Bedrock calls can target
  any region the permission set allows.

## Teardown

```bash
# Remove the account assignment and permission set via IdC console or CLI
aws sso-admin delete-account-assignment ...
aws sso-admin delete-permission-set ...

# Remove the stack
aws cloudformation delete-stack \
  --stack-name codex-bedrock-idc --region us-west-2
```

## References

- [IdC with EntraID setup guide](https://docs.aws.amazon.com/singlesignon/latest/userguide/gs-entra.html)
- [IdC with Okta setup guide](https://docs.aws.amazon.com/singlesignon/latest/userguide/gs-okta.html)
- [IdC SCIM automatic provisioning](https://docs.aws.amazon.com/singlesignon/latest/userguide/provision-automatically.html)
- [SSO session duration](https://docs.aws.amazon.com/singlesignon/latest/userguide/howtosessionduration.html)
- [AWS CLI SSO profile configuration](https://docs.aws.amazon.com/cli/latest/userguide/sso-configure-profile-token.html)
