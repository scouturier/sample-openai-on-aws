# Reference — Regions & Models

Single source of truth for "where can I run Codex on Bedrock, and with which
model IDs." Cross-check against the authoritative AWS GPT-5.4-on-Bedrock
getting-started guide — if that guide disagrees, it wins.

## Partitions

| Partition | Supported | Notes |
|---|---|---|
| `aws` (commercial) | Yes | US commercial regions only. See matrix below. |
| `aws-us-gov` (GovCloud) | Not yet | No OpenAI models published in GovCloud Bedrock at time of writing. Open question for FedRAMP customers (see PLAN). |
| `aws-cn` (China) | Not yet | Not on the OpenAI-on-Bedrock roadmap at time of writing. |

## Region × model matrix

Verified 2026-05-08 via `aws bedrock list-foundation-models` against the
sandbox account. GPT-5.4 availability confirmed for `us-west-2` from the
authoritative AWS getting-started guide ("Production region"); re-verify at
launch.

| Model ID | `us-west-2` | `us-east-1` | `us-east-2` | Notes |
|---|---|---|---|---|
| `openai.gpt-5.4` | Yes (mantle) | Unknown — verify at launch | Unknown — verify at launch | Primary model. Served via `bedrock-mantle.<region>.api.aws/openai/v1/responses`. Codex `amazon-bedrock` provider targets this endpoint. |
| `openai.gpt-oss-120b-1:0` | Yes | Yes | Yes | Standard Converse API. Useful for plumbing tests ahead of GPT-5.4 launch. |
| `openai.gpt-oss-20b-1:0` | Yes | Yes | Yes | Standard Converse API. |
| `openai.gpt-oss-safeguard-120b` | Yes | Yes | Yes | Safeguard variant. |
| `openai.gpt-oss-safeguard-20b` | Yes | Yes | Yes | Safeguard variant. |

**Recommended default:** `us-west-2` with `openai.gpt-5.4`. This is what the
getting-started guide's quickstart and every sample in this repo target.

## Endpoints

- **Standard Bedrock (Converse / InvokeModel):** `bedrock-runtime.<region>.amazonaws.com` — serves the `gpt-oss*` family today.
- **Mantle (OpenAI-compatible Responses API):** `bedrock-mantle.<region>.api.aws/openai/v1` — serves GPT-5.4. This is the endpoint the Codex `amazon-bedrock` provider and the LiteLLM Gateway `openai` → Bedrock route target.

Both endpoints accept SigV4 with service name `bedrock` (standard) or service
name `bedrock-mantle` (mantle, e.g. `--aws-sigv4 "aws:amz:us-west-2:bedrock-mantle"`).

## Quotas

Per-account Bedrock invoke quotas apply. Check Service Quotas console under
**Amazon Bedrock** → filter by the specific model ID. The AWS guide does not
publish a public default quota number; confirm with your AWS account team for
GPT-5.4 before a production rollout.

For live dashboards of quota consumption, see `operate-monitoring.md` ("Quota
monitoring" section).

## Verifying availability yourself

```bash
aws bedrock list-foundation-models \
  --region us-west-2 \
  --query "modelSummaries[?contains(modelId,'openai')].modelId" \
  --output text
```

If a model ID you need isn't in that list, model access probably isn't enabled
for the account in that region. Request access in the **Amazon Bedrock** →
**Model access** console page.
