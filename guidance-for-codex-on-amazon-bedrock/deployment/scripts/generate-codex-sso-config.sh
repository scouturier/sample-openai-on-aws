#!/usr/bin/env bash
# Generate Codex-on-Bedrock SSO config snippets for distribution to developers.
#
# Produces a self-contained bundle devs run on their own machines:
#   1. <outdir>/install.sh                -> one-shot installer (what users run)
#   2. <outdir>/aws-config.snippet        -> appended to ~/.aws/config by install.sh
#   3. <outdir>/codex-config.toml.snippet -> merged into ~/.codex/config.toml by install.sh
#   4. <outdir>/codex-sso-creds           -> credential_process helper, installed to ~/.local/bin
#   5. <outdir>/DEV-SETUP.md              -> short human-readable reference
#
# Admin runs this once per org with the IdC coordinates; the output is the
# distributable. Devs do not run this script.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate-codex-sso-config.sh [options]

Required:
  --start-url URL         IdC access portal URL (e.g. https://d-xxxx.awsapps.com/start)
  --sso-region REGION     Region hosting the IdC instance (e.g. us-east-1)
  --account-id ID         AWS account ID Codex should target
  --permission-set NAME   IdC permission set name (e.g. CodexBedrockUser)

Optional:
  --bedrock-region REGION Bedrock region for Codex calls (default: us-west-2)
  --profile-name NAME     AWS profile + Codex profile name (default: codex-bedrock)
  --sso-session NAME      SSO session name in ~/.aws/config (default: codex-bedrock)
  --model ID              Default Codex model ID (default: openai.gpt-5.4)
  --otel-endpoint URL     OTLP/HTTP endpoint for the Codex OTel collector (e.g.
                          http://otel-collector-alb-...elb.amazonaws.com). When
                          provided, the emitted Codex config includes an [otel]
                          block with x-user-id stamped from the IdC session at
                          install time.
  --outdir DIR            Output directory (default: ./codex-sso-config)
  -h, --help              Show this help
EOF
}

bedrock_region="us-west-2"
profile_name="codex-bedrock"
sso_session_name=""
model_id="openai.gpt-5.4"
outdir="./codex-sso-config"
otel_endpoint=""
start_url=""
sso_region=""
account_id=""
permission_set=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-url) start_url="$2"; shift 2;;
    --sso-region) sso_region="$2"; shift 2;;
    --account-id) account_id="$2"; shift 2;;
    --permission-set) permission_set="$2"; shift 2;;
    --bedrock-region) bedrock_region="$2"; shift 2;;
    --profile-name) profile_name="$2"; shift 2;;
    --sso-session) sso_session_name="$2"; shift 2;;
    --model) model_id="$2"; shift 2;;
    --otel-endpoint) otel_endpoint="$2"; shift 2;;
    --outdir) outdir="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage; exit 2;;
  esac
done

missing=()
[[ -z "$start_url" ]] && missing+=(--start-url)
[[ -z "$sso_region" ]] && missing+=(--sso-region)
[[ -z "$account_id" ]] && missing+=(--account-id)
[[ -z "$permission_set" ]] && missing+=(--permission-set)
if (( ${#missing[@]} )); then
  echo "missing required flags: ${missing[*]}" >&2
  usage
  exit 2
fi

[[ "$start_url" =~ ^https://.+ ]] || { echo "--start-url must be https://..." >&2; exit 2; }
[[ "$account_id" =~ ^[0-9]{12}$ ]] || { echo "--account-id must be 12 digits" >&2; exit 2; }
[[ "$sso_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || { echo "--sso-region malformed" >&2; exit 2; }
[[ "$bedrock_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || { echo "--bedrock-region malformed" >&2; exit 2; }
[[ "$permission_set" =~ ^[A-Za-z0-9+=,.@_-]{1,32}$ ]] || { echo "--permission-set invalid" >&2; exit 2; }
[[ -n "$otel_endpoint" && ! "$otel_endpoint" =~ ^https?://.+ ]] && { echo "--otel-endpoint must be http(s)://..." >&2; exit 2; }

[[ -z "$sso_session_name" ]] && sso_session_name="$profile_name"

mkdir -p "$outdir"

aws_snippet="$outdir/aws-config.snippet"
sso_profile_name="${profile_name}-sso"
cat > "$aws_snippet" <<EOF
# --- Codex-on-Bedrock SSO profile (generated) ---
[sso-session $sso_session_name]
sso_start_url = $start_url
sso_region = $sso_region
sso_registration_scopes = sso:account:access

# Base SSO profile — resolved by the credential_process helper.
[profile $sso_profile_name]
sso_session = $sso_session_name
sso_account_id = $account_id
sso_role_name = $permission_set
region = $bedrock_region

# Codex-facing profile — delegates to the helper, which auto-triggers
# 'aws sso login' when the cached token is missing or expired.
[profile $profile_name]
region = $bedrock_region
credential_process = sh -c 'exec "\$HOME/.local/bin/codex-sso-creds" $sso_profile_name $sso_session_name'
EOF

creds_helper="$outdir/codex-sso-creds"
cat > "$creds_helper" <<'HELPER'
#!/usr/bin/env bash
# credential_process helper for Codex-on-Bedrock SSO profiles.
#
# The AWS SDK invokes this from the profile's credential_process. If the cached
# SSO token is valid, we return credentials immediately. If it's missing or
# expired, we trigger `aws sso login` (opens a browser) and then return
# credentials. This keeps Codex unaware of the auth state — users just see a
# browser pop once per working day.
#
# Known footgun: if the user closes the browser before completing sign-in,
# or the invoking SDK call times out before sign-in completes (usually <30s),
# that specific call fails with a credentials error. Retry the Codex prompt
# and it will succeed. Not silent data loss.
#
# Args: $1 = AWS profile name, $2 = sso-session name
set -euo pipefail

PROFILE="${1:?profile name required}"
SESSION="${2:?sso-session name required}"

# Resolve the aws binary. GUI-launched apps (Dock, Spotlight, VS Code) don't
# inherit the shell's PATH on macOS, so we walk known install locations and
# ask launchd for the user's PATH as a last resort before giving up.
resolve_aws() {
  local bin
  bin="$(command -v aws 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] && { printf '%s' "$bin"; return; }
  local candidates=(
    /opt/homebrew/bin/aws       # macOS Apple Silicon Homebrew
    /usr/local/bin/aws          # macOS Intel Homebrew + common Linux
    /usr/bin/aws                # system package managers
    /opt/local/bin/aws          # MacPorts
    /home/linuxbrew/.linuxbrew/bin/aws  # Linuxbrew
    "$HOME/.linuxbrew/bin/aws"
    "$HOME/.local/bin/aws"      # pip --user installs
  )
  for p in "${candidates[@]}"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return; }
  done
  # Last resort on macOS: ask launchd for the user's configured PATH.
  if [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
    local launch_path
    launch_path="$(launchctl getenv PATH 2>/dev/null || true)"
    if [[ -n "$launch_path" ]]; then
      IFS=: read -r -a dirs <<< "$launch_path"
      for d in "${dirs[@]}"; do
        [[ -x "$d/aws" ]] && { printf '%s' "$d/aws"; return; }
      done
    fi
  fi
}

AWS_BIN="$(resolve_aws || true)"
if [[ -z "$AWS_BIN" ]]; then
  echo "codex-sso-creds: aws CLI v2 not found. Install with 'brew install awscli' (macOS) or your package manager." >&2
  exit 1
fi

export HOME="${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}"

emit_creds() {
  "$AWS_BIN" configure export-credentials --profile "$PROFILE" --format process
}

if emit_creds 2>/dev/null; then
  exit 0
fi

# Token missing or expired — launch interactive login, then retry.
"$AWS_BIN" sso login --sso-session "$SESSION" >&2
emit_creds
HELPER
chmod +x "$creds_helper"

codex_snippet="$outdir/codex-config.toml.snippet"
cat > "$codex_snippet" <<EOF
# --- Codex-on-Bedrock (generated) ---
# Merge into ~/.codex/config.toml
model = "$model_id"
model_provider = "amazon-bedrock"

[model_providers.amazon-bedrock.aws]
region = "$bedrock_region"
profile = "$profile_name"
EOF

if [[ -n "$otel_endpoint" ]]; then
  # install.sh substitutes __CODEX_USER__ at install time with the SSO username
  # resolved from `aws sts get-caller-identity`. Attribution is header-based
  # (see specs/02-otel-dashboard.md) — trust model is control-of-distribution,
  # not cryptographic.
  #
  # Codex treats `endpoint` as the full URL (no OTLP path appending), so each
  # signal's endpoint must include its own /v1/<signal> suffix. Verified
  # against Codex 0.130.0-alpha.7 on 2026-05-08 — without the suffix every
  # export hits the ALB root and 404s.
  trim_endpoint="${otel_endpoint%/}"
  cat >> "$codex_snippet" <<EOF

[otel]
environment = "prod"
exporter = { otlp-http = { endpoint = "$trim_endpoint/v1/logs", protocol = "binary", headers = { "x-user-id" = "__CODEX_USER__" } } }
trace_exporter = { otlp-http = { endpoint = "$trim_endpoint/v1/traces", protocol = "binary", headers = { "x-user-id" = "__CODEX_USER__" } } }
metrics_exporter = { otlp-http = { endpoint = "$trim_endpoint/v1/metrics", protocol = "binary", headers = { "x-user-id" = "__CODEX_USER__" } } }
EOF
fi

installer="$outdir/install.sh"
cat > "$installer" <<INSTALLER
#!/usr/bin/env bash
# Codex-on-Bedrock — developer installer.
#
# Idempotent. Managed sections in ~/.aws/config and ~/.codex/config.toml are
# wrapped in fenced markers so re-running this installer replaces its own
# blocks atomically instead of appending duplicates. uninstall.sh reverses.
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

PROFILE="$profile_name"
SSO_PROFILE="$sso_profile_name"
SSO_SESSION="$sso_session_name"
MARKER_BEGIN="# >>> codex-on-bedrock managed (do not edit) >>>"
MARKER_END="# <<< codex-on-bedrock managed <<<"

log() { printf '\\033[1;34m[%s]\\033[0m %s\\n' "\$(date +%H:%M:%S)" "\$*"; }
ok()  { printf '\\033[1;32m[OK]\\033[0m %s\\n' "\$*"; }
fail(){ printf '\\033[1;31m[FAIL]\\033[0m %s\\n' "\$*" >&2; exit 1; }

command -v aws >/dev/null || fail "aws CLI v2 not found. Install with: brew install awscli"

# Replace a fenced region in a file (create file if missing). Writes a backup
# next to the file on first modification so users can recover if needed.
replace_fenced_region() {
  local target="\$1" content_file="\$2"
  mkdir -p "\$(dirname "\$target")"
  touch "\$target"
  if grep -qF "\$MARKER_BEGIN" "\$target" 2>/dev/null; then
    cp "\$target" "\$target.bak.\$(date +%s)"
    python3 - "\$target" "\$content_file" "\$MARKER_BEGIN" "\$MARKER_END" <<'PY'
import sys, re
target, content, begin, end = sys.argv[1:]
src = open(target).read()
body = open(content).read().rstrip() + "\n"
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.DOTALL)
new = pattern.sub(begin + "\n" + body + end + "\n", src, count=1)
open(target, "w").write(new)
PY
  else
    {
      [[ -s "\$target" ]] && echo ""
      echo "\$MARKER_BEGIN"
      cat "\$content_file"
      echo "\$MARKER_END"
    } >> "\$target"
  fi
}

log "Installing credential_process helper to ~/.local/bin/codex-sso-creds"
mkdir -p "\$HOME/.local/bin"
install -m 0755 "\$SCRIPT_DIR/codex-sso-creds" "\$HOME/.local/bin/codex-sso-creds"
ok "helper installed"

log "Writing fenced block into ~/.aws/config"
replace_fenced_region "\$HOME/.aws/config" "\$SCRIPT_DIR/aws-config.snippet"
ok "AWS config updated"

# OTel attribution: stamp the SSO username into the Codex [otel] block if
# the snippet has one. Defer interactive sign-in out of the install path —
# if the user doesn't have a valid SSO token yet, we fall back to a
# placeholder (\$USER) and emit a note so they can re-run later.
log "Preparing Codex config"
CODEX_USER=""
if grep -q "__CODEX_USER__" "\$SCRIPT_DIR/codex-config.toml.snippet" 2>/dev/null; then
  # Try to resolve the SSO username without triggering interactive sign-in:
  # probe the cached token directly via \`aws sts get-caller-identity\`.
  # If no cached token exists the command fails quickly; we fall back to a
  # placeholder and instruct the user to re-run install.sh after signing in.
  if caller_arn=\$(aws sts get-caller-identity --profile "\$SSO_PROFILE" --query Arn --output text 2>/dev/null); then
    CODEX_USER="\${caller_arn##*/}"
    ok "resolved SSO username for OTel attribution: \$CODEX_USER"
  else
    CODEX_USER="\${USER:-unknown}"
    printf '\\033[1;33m[NOTE]\\033[0m No valid SSO session yet — stamping OTel header with %s as a placeholder.\\n' "\$CODEX_USER"
    printf '       Run \"aws sso login --sso-session %s\" then re-run install.sh to stamp your real SSO username.\\n' "\$SSO_SESSION"
  fi
fi

SNIPPET_RENDERED="\$SCRIPT_DIR/codex-config.toml.snippet.rendered"
sed "s|__CODEX_USER__|\$CODEX_USER|g" "\$SCRIPT_DIR/codex-config.toml.snippet" > "\$SNIPPET_RENDERED"
replace_fenced_region "\$HOME/.codex/config.toml" "\$SNIPPET_RENDERED"
rm -f "\$SNIPPET_RENDERED"
ok "Codex config updated"

cat <<DONE

Installation complete.

Next: launch Codex (CLI, desktop app, or VS Code extension).
On first use, a browser window opens automatically for IdC sign-in.
Subsequent launches reuse the cached session silently (8h default).

If Codex ever errors with a credential problem mid-day, retry the prompt —
the browser sign-in had to pop and the first SDK call raced the token
refresh. The next call will succeed.

To remove: ./uninstall.sh
DONE
INSTALLER
chmod +x "$installer"

uninstaller="$outdir/uninstall.sh"
cat > "$uninstaller" <<UNINSTALLER
#!/usr/bin/env bash
# Codex-on-Bedrock — developer uninstaller.
# Removes the fenced managed blocks from ~/.aws/config and
# ~/.codex/config.toml, deletes the credential_process helper, and preserves
# backups so users can recover if needed.
set -euo pipefail

MARKER_BEGIN="# >>> codex-on-bedrock managed (do not edit) >>>"
MARKER_END="# <<< codex-on-bedrock managed <<<"

log() { printf '\\033[1;34m[%s]\\033[0m %s\\n' "\$(date +%H:%M:%S)" "\$*"; }
ok()  { printf '\\033[1;32m[OK]\\033[0m %s\\n' "\$*"; }

remove_fenced_region() {
  local target="\$1"
  [[ -f "\$target" ]] || { ok "\$target not present, skipping"; return; }
  if grep -qF "\$MARKER_BEGIN" "\$target"; then
    cp "\$target" "\$target.bak.\$(date +%s)"
    python3 - "\$target" "\$MARKER_BEGIN" "\$MARKER_END" <<'PY'
import sys, re
target, begin, end = sys.argv[1:]
src = open(target).read()
pattern = re.compile(r"\n*" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.DOTALL)
open(target, "w").write(pattern.sub("", src, count=1))
PY
    ok "removed managed block from \$target (backup saved)"
  else
    ok "no managed block in \$target, skipping"
  fi
}

log "Removing ~/.local/bin/codex-sso-creds"
rm -f "\$HOME/.local/bin/codex-sso-creds"
ok "helper removed"

log "Cleaning ~/.aws/config"
remove_fenced_region "\$HOME/.aws/config"

log "Cleaning ~/.codex/config.toml"
remove_fenced_region "\$HOME/.codex/config.toml"

cat <<DONE

Uninstall complete. Backups saved with .bak.<timestamp> suffix next to each
modified file. To fully revert, restore from a backup and remove the helper
cache at ~/.aws/sso/cache if you want to force a fresh IdC sign-in next time.
DONE
UNINSTALLER
chmod +x "$uninstaller"

dev_readme="$outdir/DEV-SETUP.md"
cat > "$dev_readme" <<EOF
# Codex on Amazon Bedrock — developer setup

Time to complete: ~2 minutes.

## Prerequisites

- AWS CLI v2 installed (\`aws --version\` reports 2.x)
- Codex CLI >= 0.128.0, or Codex desktop app / VS Code extension >= 26.429.30905

## 1. Run the installer

\`\`\`bash
./install.sh
\`\`\`

The installer is idempotent. It:
- copies \`codex-sso-creds\` to \`~/.local/bin/\`
- wraps its managed content in fenced markers inside \`~/.aws/config\` and \`~/.codex/config.toml\` so re-running replaces its own block atomically (a timestamped \`.bak\` is written next to each file on first modification).

## 2. Run Codex

Launch \`codex\` (or the desktop app / VS Code extension). On first use, a
browser window opens automatically for IdC sign-in. Subsequent launches reuse
the cached session silently.

Run \`/status\` in Codex to verify \`amazon-bedrock\` / \`$model_id\`.

## How auth works

The AWS profile \`$profile_name\` uses \`credential_process\` to invoke
\`~/.local/bin/codex-sso-creds\`. If the IdC session is valid, credentials are
returned immediately. If the session is missing or expired, the helper runs
\`aws sso login\` transparently — users just see the browser pop once per
working day (IdC default: 8h).

No manual \`aws sso login\` is needed, and no environment variables are
required.

**Known corner case:** if the user closes the sign-in browser before
completing it, or the very first Codex call races the token-refresh
completion, that one call may fail with a credential error. Retry the Codex
prompt and it will succeed — the cached token is now valid.

## Removing

\`\`\`bash
./uninstall.sh
\`\`\`

Removes the helper binary, strips the fenced managed blocks from
\`~/.aws/config\` and \`~/.codex/config.toml\`, and saves backups of both files
next to the originals.
EOF

cat <<EOF
Generated:
  $installer
  $uninstaller
  $aws_snippet
  $codex_snippet
  $creds_helper
  $dev_readme

Distribute the '$outdir/' directory to developers. Users run install.sh;
uninstall.sh reverses everything and saves backups.
EOF
