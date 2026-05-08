#!/usr/bin/env bash
# Deploy the Codex-on-Bedrock OTel telemetry stack end-to-end:
#   1. networking.yaml       — VPC + public subnets for the collector
#   2. otel-collector.yaml   — ADOT collector on Fargate behind an ALB
#   3. codex-otel-dashboard.yaml — CloudWatch dashboard (usage + spend estimate)
#
# Emits the ALB endpoint so you can feed it into generate-codex-sso-config.sh
# via --otel-endpoint.
#
# Prereqs:
#   - AWS CLI v2 configured against the target account/region
#   - The IdC + Bedrock auth stack is a separate concern (bedrock-auth-idc.yaml)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-otel-stack.sh [options]

Options:
  --region REGION              AWS region (default: us-west-2)
  --stack-prefix PREFIX        Prefix for all three stacks (default: codex-otel)
  --dashboard-name NAME        CloudWatch dashboard name (default: CodexOnBedrock)
  --input-price N              USD per 1M input tokens (default: 0.15, placeholder)
  --output-price N             USD per 1M output tokens (default: 0.60, placeholder)
  --cached-input-price N       USD per 1M cached-input tokens (default: 0.075, placeholder)

HTTPS + JWT validation (production hardening — opt-in).
If any of the flags below are provided, ALL are required. Without them the
collector deploys in HTTP-only mode, which is OK for sandbox but publishes
Codex telemetry over the public internet unauthenticated (trust-on-
distribution). See specs/02-otel-dashboard.md for trade-offs.

  --custom-domain FQDN         FQDN for the collector ALB (e.g. otel.codex.example.com).
                               ACM cert is provisioned automatically via DNS validation.
  --hosted-zone-id ID          Route 53 hosted zone ID that owns the FQDN.
  --oidc-issuer URL            OIDC issuer URL (e.g. https://cognito-idp.<region>.amazonaws.com/<pool-id>).
  --oidc-jwks URL              JWKS endpoint (typically <issuer>/.well-known/jwks.json).
  --oidc-client-id ID          OIDC app client ID — used as 'aud' claim validation at the ALB.

  -h, --help                   Show this help

After deploy completes, the collector endpoint is printed. Pass it to
generate-codex-sso-config.sh with --otel-endpoint to bake it into the
distributed Codex config. When JWT validation is enabled, each developer
also needs to supply a bearer token — set via static header in the Codex
config, e.g. `headers = { "Authorization" = "Bearer \${CODEX_OTEL_TOKEN}" }`.
EOF
}

region="us-west-2"
prefix="codex-otel"
dashboard_name="CodexOnBedrock"
input_price="0.15"
output_price="0.60"
cached_input_price="0.075"
custom_domain=""
hosted_zone_id=""
oidc_issuer=""
oidc_jwks=""
oidc_client_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) region="$2"; shift 2;;
    --stack-prefix) prefix="$2"; shift 2;;
    --dashboard-name) dashboard_name="$2"; shift 2;;
    --input-price) input_price="$2"; shift 2;;
    --output-price) output_price="$2"; shift 2;;
    --cached-input-price) cached_input_price="$2"; shift 2;;
    --custom-domain) custom_domain="$2"; shift 2;;
    --hosted-zone-id) hosted_zone_id="$2"; shift 2;;
    --oidc-issuer) oidc_issuer="$2"; shift 2;;
    --oidc-jwks) oidc_jwks="$2"; shift 2;;
    --oidc-client-id) oidc_client_id="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown flag: $1" >&2; usage; exit 2;;
  esac
done

# HTTPS and JWT are independently optional (mirrors the claude-code
# guidance). ALB jwt-validation action is HTTPS-only (confirmed via CFN
# deploy probe 2026-05-08: "Actions of type 'jwt-validation' are supported
# only on HTTPS listeners"), so --oidc-* without --custom-domain has no
# effect. Warn but don't block.
https_on=0; jwt_on=0
[[ -n "$custom_domain" && -n "$hosted_zone_id" ]] && https_on=1
[[ -n "$oidc_issuer" && -n "$oidc_jwks" ]] && jwt_on=1
if (( jwt_on == 1 && https_on == 0 )); then
  echo "Warning: --oidc-* flags require HTTPS (--custom-domain + --hosted-zone-id). JWT validation will be skipped." >&2
fi

infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infrastructure" && pwd)"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

net_stack="${prefix}-networking"
col_stack="${prefix}-collector"
dash_stack="${prefix}-dashboard"

log "Deploying networking stack: $net_stack"
aws cloudformation deploy \
  --region "$region" \
  --stack-name "$net_stack" \
  --template-file "$infra_dir/networking.yaml" \
  --no-fail-on-empty-changeset >/dev/null
ok "networking ready"

vpc_id=$(aws cloudformation describe-stacks --region "$region" --stack-name "$net_stack" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
subnet_ids=$(aws cloudformation describe-stacks --region "$region" --stack-name "$net_stack" \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetIds'].OutputValue" --output text)

collector_params=(VpcId="$vpc_id" SubnetIds="$subnet_ids")
[[ -n "$custom_domain" ]]    && collector_params+=(CustomDomainName="$custom_domain")
[[ -n "$hosted_zone_id" ]]   && collector_params+=(HostedZoneId="$hosted_zone_id")
[[ -n "$oidc_issuer" ]]      && collector_params+=(OidcIssuerUrl="$oidc_issuer")
[[ -n "$oidc_jwks" ]]        && collector_params+=(OidcJwksEndpoint="$oidc_jwks")
[[ -n "$oidc_client_id" ]]   && collector_params+=(OidcClientId="$oidc_client_id")

if (( https_on == 1 && jwt_on == 1 )); then
  log "Collector posture: HTTPS + JWT validation (domain=$custom_domain issuer=$oidc_issuer)"
elif (( https_on == 1 )); then
  log "Collector posture: HTTPS, no auth (encrypted in transit; attribution is header-based)"
else
  log "Collector posture: HTTP, no auth (sandbox default — data is NOT encrypted in transit)"
fi

log "Deploying collector stack: $col_stack (VPC $vpc_id)"
aws cloudformation deploy \
  --region "$region" \
  --stack-name "$col_stack" \
  --template-file "$infra_dir/otel-collector.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "${collector_params[@]}" \
  --no-fail-on-empty-changeset >/dev/null
ok "collector ready"

collector_endpoint=$(aws cloudformation describe-stacks --region "$region" --stack-name "$col_stack" \
  --query "Stacks[0].Outputs[?OutputKey=='CollectorEndpoint'].OutputValue" --output text)

log "Deploying dashboard stack: $dash_stack"
aws cloudformation deploy \
  --region "$region" \
  --stack-name "$dash_stack" \
  --template-file "$infra_dir/codex-otel-dashboard.yaml" \
  --parameter-overrides \
      DashboardName="$dashboard_name" \
      InputTokenPriceUsdPerMillion="$input_price" \
      OutputTokenPriceUsdPerMillion="$output_price" \
      CachedInputTokenPriceUsdPerMillion="$cached_input_price" \
  --no-fail-on-empty-changeset >/dev/null
ok "dashboard ready"

dashboard_url=$(aws cloudformation describe-stacks --region "$region" --stack-name "$dash_stack" \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardURL'].OutputValue" --output text)

cat <<EOF

==========================================================================
Codex OTel stack deployed.

Collector endpoint:  $collector_endpoint
Dashboard:           $dashboard_url

Next step — generate the distributable Codex config pointing at the
collector, e.g.:

  ./generate-codex-sso-config.sh \\
      --start-url <your-idc-start-url> \\
      --sso-region <idc-region> \\
      --account-id <account-id> \\
      --permission-set CodexBedrockUser \\
      --bedrock-region $region \\
      --otel-endpoint $collector_endpoint \\
      --outdir ./codex-sso-config

Teardown (reverse order):
  aws cloudformation delete-stack --region $region --stack-name $dash_stack
  aws cloudformation delete-stack --region $region --stack-name $col_stack
  aws cloudformation delete-stack --region $region --stack-name $net_stack
==========================================================================
EOF
