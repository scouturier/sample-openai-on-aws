# Decide

Two deployment paths, in recommended order. Pick the first one your org can
actually run.

> **Decision rule:** If you can run IAM Identity Center, use IAM Identity Center.
> If you can't and you need centralized enforcement or multi-provider fan-out,
> run the Gateway.

| | **IAM Identity Center** (recommended) | **Gateway** (alternative) |
|---|---|---|
| Developer setup | `aws sso login` via AWS CLI v2 | Set `OPENAI_BASE_URL` + present OIDC JWT |
| Binary distribution | Signed AWS CLI v2 (winget/MSI/brew/MDM) | None |
| Infra to run | None (free AWS control plane) | ECS Fargate + ALB + Postgres (~$90–150/mo + 0.1–0.25 FTE) |
| Bedrock auth | Per-user federated IAM credentials | Gateway IAM task role |
| Per-user attribution | CloudTrail `userIdentity` (SSO username) | JWT claims via OTel |
| Hard per-user budgets | No (attribution only) | Yes (LiteLLM budget/rate limits) |
| Codex provider | Native `amazon-bedrock` | Generic `openai` (loses native path) |
| FedRAMP/GovCloud | IdC in GovCloud partition | ECS on GovCloud |

## Prereq checklist — IAM Identity Center

Run this path if **all** of the following hold:

- [ ] AWS Organizations is enabled (or you can enable it).
- [ ] Your IdP supports SAML 2.0 + SCIM 2.0 (EntraID, Okta, Ping, JumpCloud,
      Google Workspace, CyberArk, OneLogin).
- [ ] You can distribute AWS CLI v2 to developers (winget / MSI / Homebrew /
      MDM).
- [ ] Amazon Bedrock is activated in at least one region you plan to use
      (today: `us-west-2` for GPT-5.4).
- [ ] Per-user *attribution* in CloudTrail/CUR is sufficient — you do **not**
      require hard per-user token/cost cutoffs.

If all five check, go to [Deploy — IAM Identity Center](deploy-identity-center.md).

## Prereq checklist — Gateway

Run this path if IdC is off the table **or** you need enforcement /
multi-provider fan-out. All of the following must hold:

- [ ] IdC is not achievable, **or** you need one of: hard per-user token/cost
      budgets with automatic cutoff; multi-provider fan-out (Bedrock + Azure
      OpenAI + self-hosted) behind one endpoint; reuse of an existing
      platform-team gateway.
- [ ] You have a container runtime you can operate (ECS Fargate, EKS, or
      equivalent) plus ALB and Postgres. Reference LiteLLM footprint is
      ~$90–150/mo + 0.1–0.25 FTE of ongoing ops.
- [ ] You have an OIDC IdP that can issue JWTs to developer machines (for
      client → gateway auth).
- [ ] You accept Codex running as a generic OpenAI provider (`model_provider
      = "openai"` + custom `base_url`), bypassing the native `amazon-bedrock`
      code path.
- [ ] Amazon Bedrock is activated in the region the gateway task role will
      call (today: `us-west-2` for GPT-5.4).

**Reference implementation:** this repo ships LiteLLM under
`deployment/litellm/` as a working example. The pattern applies equally to
other OpenAI-compatible gateways — **Portkey**, **Kong AI Gateway**,
**Helicone**, the **AWS Bedrock Gateway** sample, or a custom FastAPI shim.
Pick whichever matches your org's operational posture.

*(Canonical deploy doc: `deploy-gateway.md`.)*

## Why this order

1. **Enterprise audience needs centralized cost + usage attribution with
   scalable distribution.** That eliminates the static Bedrock API key as a
   ranked option — it's documented in Bedrock's own docs as a pilot/POC
   mechanism, not an enterprise path.
2. **IdC delivers all three off one identity plane.** SSO user name in
   CloudTrail → CUR attribution; same identity stamped into OTel as
   `user.id` → CloudWatch dashboards; signed AWS CLI v2 distribution →
   zero SmartScreen/Gatekeeper friction.
3. **The gateway's historical advantage is gone for Codex.** Codex natively
   speaks SigV4 to Bedrock via the AWS SDK credential chain. Pointing Codex at
   a gateway forces `model_provider = "openai"` with a custom `base_url`,
   abandoning the native `amazon-bedrock` code path. The gateway retains real
   value only for *enforcement* and *multi-provider* fan-out.

## Open questions that may shift the pick

- **Session duration vs. long Codex runs.** 8h default IdC session can
  interrupt multi-hour agent runs. Raise permission-set session duration or
  accept `aws sso login` re-auth as expected UX.
- **GovCloud parity.** Whether IdC-in-GovCloud meets the FedRAMP alignment
  some customers require is not yet confirmed.
