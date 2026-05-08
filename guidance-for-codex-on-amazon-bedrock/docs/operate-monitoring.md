# Operate — Monitoring & Cost Attribution

How to see who's using Codex, what they're spending, and when to alert.

Both deploy paths (IdC and Gateway) end in a user-scoped IAM session invoking
Bedrock. That single identity fans out into two authoritative signals —
**CloudTrail → CUR** for cost, **OTel → CloudWatch** for usage — plus an
optional cold-storage pipeline for deep historical queries.

## The identity chain

```
Corporate IdP (EntraID / Okta / …)
  └── SAML → IAM Identity Center
       └── aws sso login → temporary IAM credentials (assumed role)
            ├── bedrock:InvokeModel call
            │    └── CloudTrail userIdentity (SSO username)
            │         └── CUR 2.0 (line_item_iam_principal + cost-alloc tags)
            │              └── Per-user / per-team spend ← source of truth
            └── Codex OTel exporter (x-user-id header, install-time baked)
                 └── ADOT collector on ECS Fargate
                      └── CloudWatch EMF metrics (user.id dimension)
                           └── Per-user / per-team usage dashboard + quotas
```

Single identity, two dashboards. The Gateway path splits this into two
planes (JWT for attribution, task role for Bedrock) — see the gateway
caveat at the end.

This diagram is the canonical version. Other docs link here; do not copy.

---

## Three layers

| Layer | Purpose | Latency | Storage | Authority |
|---|---|---|---|---|
| **Live dashboards + quota alerts** | "What's happening now. Who's over budget." | ~60s | CloudWatch Metrics + Logs | Usage only |
| **Cost attribution** | "What did each user / team cost this month." | ~24h | CUR 2.0 on S3 | Billing-grade |
| **Deep historical analytics** (optional) | Arbitrary SQL over months of token-level data. | ~5min | S3 Parquet + Athena | Usage only |

Pick the layers you need. Most orgs run **live + cost**; only add the
analytics pipeline when CUR can't answer the question (per-turn token
counts, TPM/RPM spikes, session-duration studies).

---

## Layer 1 — Live dashboards + quota alerts (CloudWatch)

### What's deployed

`deploy-otel-stack.sh` (used from the IdC and Gateway deploy docs) creates:

- **OTel collector** (ECS Fargate, `otel-collector.yaml`) behind an ALB.
  Receives OTLP/HTTP, maps the `x-user-id` header → `user.id` resource
  attribute, exports EMF to CloudWatch namespace `Codex`.
- **CloudWatch dashboard** `CodexOnBedrock` (`codex-otel-dashboard.yaml`) —
  per-user token spend estimate, API error rate, turn latency, session-source
  mix, active-developer leaderboard.

End users emit metrics automatically once their generated `~/.codex/config.toml`
ships with an `[otel]` block pointing at your collector (the generator bakes
this in — see `deploy-identity-center.md` §5).

### Metrics Codex actually emits

Verified against Codex 0.130.0-alpha.7 (2026-05-08):

- `codex.api_request`, `codex.api_request.duration_ms` — HTTP call count + latency; dimension `status`.
- `codex.turn.e2e_duration_ms` — wall-clock per turn.
- `codex.turn.token_usage` — dimension `token_type` ∈ {input, output, cached_input, reasoning_output, total}.
- `codex.turn.tool.call`, `codex.turn.memory`, `codex.turn.network_proxy`.
- `codex.thread.started`, `codex.thread.skills.*`.
- `codex.shell_snapshot(.duration_ms)`, `codex.startup_prewarm.*`, `codex.plugins.startup_sync(.final)`, `codex.conversation.turn.count`.

Codex auto-stamps resource attrs: `service.name=codex_cli_rs`, `service.version`,
`app.version`, `model`, `originator`, `session_source`, `os`. These become
additional CloudWatch dimensions.

### Spend estimates on the live dashboard

The dashboard multiplies `codex.turn.token_usage` by list price per 1M tokens
(defaults in `codex-otel-dashboard.yaml` — placeholder figures until GPT-5.4
pricing ships). **These are estimates.** Ground truth is CUR (Layer 2). If
numbers disagree, trust CUR.

### Quota alerts

Under IdC there is **no credential issuer to gate**: IdC hands out session
credentials directly, and you can't revoke them mid-session on token overage.

Recommended posture under IdC:

- **Soft alerts via CloudWatch alarms** on `codex.turn.token_usage` summed by
  `user.id` over a rolling window. Wire to SNS for email / Slack.
- **Hard enforcement, if required, via the Gateway path.** LiteLLM's
  per-user/per-key budget controls sit in the request path and can actually
  deny.

---

## Layer 2 — Cost attribution (CloudTrail → CUR 2.0)

**Cleanest under IdC.** The Gateway path sees only the gateway's task role
in CloudTrail (see gateway caveat below).

### Per-user: built-in, no IdP changes

Every `bedrock:InvokeModel` call carries the SSO username in
`userIdentity.principalId`, which shows up in CUR 2.0 under
`line_item_iam_principal` as:

```
arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_CodexBedrockUser_…/alice@example.com
```

Enable it:

1. Billing → **Data Exports** → create or edit a Standard CUR 2.0 export.
2. Under **Additional export content**, enable **"Include caller identity
   (IAM principal) allocation data"**.
3. Query via Athena:

```sql
SELECT line_item_iam_principal, SUM(line_item_unblended_cost) AS usd
FROM cur2
WHERE line_item_product_code = 'AmazonBedrock'
  AND year = '2026' AND month = '5'
GROUP BY 1 ORDER BY usd DESC;
```

Cost Explorer does **not** expose `line_item_iam_principal` as a
filter/grouping dimension — you need Athena or QuickSight. If you want per-user
visibility *in Cost Explorer*, add session tags (next section).

### Per-team: IAM principal tags

All IdC users share the same role, so role-level tags give team/department
rollups only — not per-user.

1. Tag the `CodexBedrockUser` role (or its permission-set-backed role) with
   `department`, `cost-center`, etc.
2. Billing → **Cost Allocation Tags** → filter by **IAM principal type**,
   select, **Activate**.
3. Tags take up to 24h to appear after the first tagged call, then up to 24h
   more to activate.

### Session tags for per-user Cost Explorer visibility

Optional. Needed only if you want per-user grouping in Cost Explorer (not just
Athena). Embed an `https://aws.amazon.com/tags` claim in the IdP's ID token —
formats vary per IdP (Auth0 nested object; Okta/Entra flattened per-key).
See the [AWS STS session-tags guide](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_session-tags.html)
for claim formats per IdP — this is an IdP-side customization, not
Codex-specific.

The role's trust policy must allow `sts:TagSession` or
`AssumeRoleWithWebIdentity` fails outright.

---

## Layer 3 — Deep historical analytics (optional)

When CUR and live dashboards don't answer the question — typically token-level
studies, TPM/RPM spike analysis, or multi-month session correlation — enable
the analytics pipeline:

- **Kinesis Firehose** streams `/aws/codex/metrics` CloudWatch Logs to S3 as
  Parquet, partitioned by `year/month/day/hour`.
- **Athena** with partition projection (no Glue crawler) queries the lake.
- **S3 lifecycle** transitions to Glacier after 90 days.

Cost: Firehose + S3 + Athena scans. For most orgs, CUR + live dashboards
suffice; enable this pipeline only when you have a real query that needs it.
A CloudFormation template for this pipeline is not shipped in this repo —
build it when the need is concrete.

---

## Gateway path caveat

If you run the LiteLLM Gateway (Path 2), the identity chain splits:

- **CloudTrail** sees only the gateway's task role on every `InvokeModel`.
  `line_item_iam_principal` can no longer attribute cost to end users.
- **Cost attribution** moves into the gateway's spend logs (LiteLLM's
  Postgres tables, keyed by the JWT subject). Export to Prometheus or
  Athena-over-S3 for durable reporting.
- **Usage (OTel)** works the same as IdC — Codex still emits, the collector
  still tags `user.id` from the header. But now you're maintaining two
  attribution planes (gateway spend DB + OTel) that need to be joined by
  username in whatever BI layer you use.

This is the principal operational cost of choosing the Gateway path. See
`deploy-gateway.md` for setup and the LiteLLM spend-table schema.

---

## Verification checklist

After deploying the OTel stack and generating developer configs:

1. **Metric lands in CloudWatch.** `aws logs tail /aws/codex/metrics
   --region us-west-2 --follow` should show EMF events with `user.id`
   dimensions within ~60s of a Codex call.
2. **Dashboard renders per-user.** Open the `CodexOnBedrock` dashboard;
   "Estimated token spend per user" bar chart should show at least one
   user after a real session.
3. **CloudTrail logs the SSO username.** `aws cloudtrail lookup-events
   --lookup-attributes AttributeKey=EventName,AttributeValue=InvokeModel
   --region us-west-2` — `userIdentity.principalId` should contain the
   SSO email after the `/`.
4. **CUR principal column populates.** Up to 24h after the first invoke,
   `line_item_iam_principal` in your CUR 2.0 export should contain the
   same SSO email.

Steps 1–3 are seconds-to-minutes. Step 4 is the CUR latency — plan on a day
before per-user spend shows up in Athena.
