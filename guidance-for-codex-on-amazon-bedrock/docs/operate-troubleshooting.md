# Operate — Troubleshooting

Known failure modes across the three deploy paths, harvested from
sandbox E2Es. Not exhaustive — add entries as new failure modes surface.

Symptoms are grouped by path. The **All paths** section applies
regardless of how you deployed.

---

## All paths

### `bedrock:InvokeModel` returns `AccessDeniedException`
- **Likely cause:** the caller's role has the Bedrock customer-managed
  policy attached, but the session doesn't match the trust policy's
  `aws:PrincipalArn` condition (`AWSReservedSSO_CodexBedrockUser_*`).
- **Fix:** verify `aws sts get-caller-identity` returns an ARN matching the
  permission-set name baked into the stack. If you renamed the permission
  set, redeploy `bedrock-auth-idc.yaml` with the new
  `PermissionSetNamePrefix` parameter.

### Model ID returns 404 / `ResourceNotFoundException`
- **Likely cause:** the model ID in `~/.codex/config.toml` (or gateway
  `litellm_config.yaml`) isn't available in the target region, or it's
  only served through the mantle endpoint (GPT-5.4) and you're calling
  standard Converse, or vice-versa.
- **Fix:** cross-check the model ID against the authoritative region
  matrix at launch. Pre-launch, `openai.gpt-oss-120b-1:0` works via
  standard Converse; `gpt-5.4` only via the mantle endpoint. See the
  GPT-5.4 pre-flight checklist.

### CloudTrail `userIdentity.principalId` shows assumed-role ARN, not SSO username
- **Expected.** The SSO username lives in `userIdentity.onBehalfOf` or is
  parsed out of the assumed-role session name (`...:<sso-username>`). CUR
  2.0's `line_item_iam_principal` column contains the full assumed-role
  ARN; join on the session-name suffix for per-user attribution.

---

## IdC path

### `aws sso login` opens browser but Codex still fails with expired creds
- **Likely cause:** `credential_process` helper (`codex-sso-creds`) raced
  the browser sign-in — Codex made its SDK call before the SSO cache was
  populated.
- **Fix:** re-run the Codex prompt. Documented as expected UX in
  `DEV-SETUP.md`. If it persists, check `~/.aws/sso/cache/` has a fresh
  JSON blob with a future `expiresAt`.

### `codex-sso-creds` works from terminal but not from the Codex desktop app / VS Code
- **Likely cause:** GUI apps on macOS launch with a minimal PATH; the
  helper can't find `aws`.
- **Fix:** the shipped helper probes Apple-Silicon + Intel Homebrew,
  MacPorts, Linuxbrew, pip-user, and system paths, plus
  `launchctl getenv PATH` as a fallback. If none resolve, symlink `aws`
  into `/usr/local/bin` or add an explicit path in the helper's candidate
  list.

### `install.sh` edits `~/.codex/config.toml` but the `[otel]` block is missing
- **Cause (fixed 2026-05-08):** old idempotency guard skipped the OTel
  block whenever the `model_providers.amazon-bedrock` block already
  existed. Guard now checks both independently.
- **Fix:** re-run `install.sh` with a current bundle; managed fences
  handle the merge.

---

## Gateway (LiteLLM) path

### `cloudformation delete-stack` on `codex-litellm-gateway` hangs on RDS
- **Cause:** `DeletionProtection: true` on the RDS instance — CFN can't
  delete it until protection is cleared.
- **Fix:**
  ```bash
  aws rds modify-db-instance \
    --db-instance-identifier <id> \
    --no-deletion-protection --apply-immediately
  ```
  Then retry the stack delete.

### Gateway `POST /v1/chat/completions` from outside the VPC times out
- **Cause:** ALB `AllowedCidr` defaults to `10.0.0.0/16` — by design, the
  gateway is internal-only.
- **Fix:** either deploy a bastion / connect through the corporate VPN, or
  temporarily add a `/32` ingress rule to the ALB security group for
  testing. Remove after.

### LiteLLM returns `400` with `"LLM Provider NOT provided"`
- **Cause:** the `model` parameter in the request doesn't match an alias
  in `litellm_config.yaml`.
- **Fix:** use one of the aliases defined in the baked config (e.g.
  `gpt-oss-120b`), or rebuild the image after editing the config.

---

## Observability (OTel → CloudWatch)

### No metrics in `/aws/codex/metrics` after a Codex session
- **Checklist:**
  1. `curl <collector-alb>/v1/metrics` with an `x-user-id` header — does
     synthetic POST land? If no, the collector or networking is broken.
  2. Check `~/.codex/config.toml` has an `[otel.exporter.otlp-http]`
     block with the *full* URL (Codex does not append `/v1/<signal>`).
  3. Check Codex version ≥ 0.130 — older versions emit a different
     metric-name set than what `otel-collector.yaml` declares.
  4. Wait ≥60s — the batch processor flushes on an interval.

### Metrics land but `user.id` dimension is empty or `$USER` placeholder
- **Cause:** `install.sh` ran before an SSO session was cached, so it fell
  back to `$USER` as the `x-user-id` header value.
- **Fix:** re-run `install.sh` after a successful `aws sso login`; the
  bundle re-bakes the header from `sts:GetCallerIdentity`.

### Collector logs show `404` on `/v1/logs` or `/v1/traces`
- **Expected pre-fix; fixed 2026-05-08.** Codex emits logs + traces
  alongside metrics; the collector now has `nop`-exporter pipelines so
  clients don't spin on 4xx. If you're seeing this, your collector
  template predates the fix — redeploy with current `otel-collector.yaml`.
