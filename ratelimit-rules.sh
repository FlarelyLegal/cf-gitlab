#!/usr/bin/env bash
set -euo pipefail

# ─── Rate Limit Rule Provisioning for GitLab Health Endpoints ─────────────────
# Creates a rate limiting rule on Cloudflare to protect /-/health, /-/liveness,
# and /-/readiness from abuse.
#
# Usage:
#   ./ratelimit-rules.sh              # provision rules
#   ./ratelimit-rules.sh --dry-run    # show what would be created
#
# Requires: CF_ZONE_ID + GITLAB_DOMAIN in .env
#           CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL in shell env (Global API key)
#           (or CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL in environment)
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Rate limit provisioning failed at line ${LINENO}."' ERR

# ─── Check required commands ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  printf '%s\n' "✗ python3 is required but not found"
  exit 1
fi

# ─── Load .env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

# ─── Resolve auth ────────────────────────────────────────────────────────────
# Uses Global API key from shell env (CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL).
# These must be set in your shell profile — they are NOT in .env.
if [[ -z "${CLOUDFLARE_API_KEY:-}" || -z "${CLOUDFLARE_EMAIL:-}" ]]; then
  printf '%s\n' "✗ Missing CLOUDFLARE_API_KEY or CLOUDFLARE_EMAIL in environment."
  exit 1
fi
AUTH_HEADERS=(-H "X-Auth-Email: ${CLOUDFLARE_EMAIL}" -H "X-Auth-Key: ${CLOUDFLARE_API_KEY}")

# ─── Validate required variables ──────────────────────────────────────────────
for var in CF_ZONE_ID GITLAB_DOMAIN; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "✗ Missing ${var} — set it in .env"
    exit 1
  fi
done

ZONE_ID="${CF_ZONE_ID}"
HOST="${GITLAB_DOMAIN}"
NON_HEALTH_COUNT=0

printf '%s\n' "── Rate Limit Rules for ${HOST} (zone: ${ZONE_ID}) ──"
printf '\n'

# ─── Build the rule payload ──────────────────────────────────────────────────
# 20 requests per 60 seconds per IP per colo — generous for monitoring,
# blocks sustained abuse. Mitigation lasts 60 seconds.
PAYLOAD=$(cat <<JSON
{
  "rules": [
    {
      "action": "block",
      "description": "Rate limit GitLab health endpoints",
      "enabled": true,
      "expression": "(http.host eq \"${HOST}\" and (starts_with(http.request.uri.path, \"/-/health\") or starts_with(http.request.uri.path, \"/-/liveness\") or starts_with(http.request.uri.path, \"/-/readiness\")))",
      "ratelimit": {
        "characteristics": ["ip.src", "cf.colo.id"],
        "mitigation_timeout": 60,
        "period": 60,
        "requests_per_period": 20
      }
    }
  ]
}
JSON
)

# ─── Find existing rate limit ruleset and preserve non-health rules ──────────
printf '%s\n' "→ Reading existing rate limit rules..."
API_BASE="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets"
EXISTING_ID=$(curl -s \
  "${AUTH_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  "${API_BASE}" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('result', []):
    if r.get('phase') == 'http_ratelimit' and r.get('kind') == 'zone':
        print(r['id'])
        break
" 2>/dev/null || true)

NON_HEALTH_RULES="[]"
if [[ -n "${EXISTING_ID}" ]]; then
  printf '%s\n' "  Found existing ruleset: ${EXISTING_ID}"
  NON_HEALTH_RULES=$(curl -s \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    "${API_BASE}/${EXISTING_ID}" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
rules = data.get('result', {}).get('rules', [])
non_health = [r for r in rules if 'health' not in r.get('description', '').lower()]
for r in non_health:
    for key in ['id', 'ref', 'version', 'last_updated']:
        r.pop(key, None)
print(json.dumps(non_health))
" 2>/dev/null)
  NON_HEALTH_COUNT=$(printf '%s\n' "${NON_HEALTH_RULES}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  printf '%s\n' "  Found ${NON_HEALTH_COUNT} non-health rules to preserve"
else
  printf '%s\n' "  No existing rate limit ruleset found"
fi

# ─── Merge health rules + non-health rules ───────────────────────────────────
HEALTH_RULES=$(printf '%s\n' "${PAYLOAD}" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['rules']))")
MERGED_RULES=$(A_JSON="${NON_HEALTH_RULES}" B_JSON="${HEALTH_RULES}" python3 -c "
import json, os
a = json.loads(os.environ['A_JSON'])
b = json.loads(os.environ['B_JSON'])
print(json.dumps(a + b))
")

TOTAL_COUNT=$(printf '%s\n' "${MERGED_RULES}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if ${DRY_RUN}; then
  printf '\n'
  printf '%s\n' "── Dry run — would provision ${TOTAL_COUNT} rules: ──"
  printf '\n'
  printf '%s\n' "${MERGED_RULES}" | python3 -m json.tool
  printf '\n'
  printf '%s\n' "✓ Dry run complete. Run without --dry-run to provision."
  exit 0
fi

# ─── Write rules ──────────────────────────────────────────────────────────────
WRITE_PAYLOAD="{\"rules\": ${MERGED_RULES}}"

if [[ -n "${EXISTING_ID}" ]]; then
  printf '%s\n' "→ Updating rate limit ruleset ${EXISTING_ID}..."
  RESPONSE=$(curl -s -X PUT \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    -d "${WRITE_PAYLOAD}" \
    "${API_BASE}/${EXISTING_ID}")
else
  printf '%s\n' "→ Creating new rate limit ruleset..."
  WRITE_PAYLOAD=$(printf '%s\n' "${WRITE_PAYLOAD}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['name'] = 'default'
data['kind'] = 'zone'
data['phase'] = 'http_ratelimit'
print(json.dumps(data))
")
  RESPONSE=$(curl -s -X POST \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    -d "${WRITE_PAYLOAD}" \
    "${API_BASE}")
fi

# ─── Check result ─────────────────────────────────────────────────────────────
HTTP_SUCCESS=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null || printf '%s\n' "false")

if [[ "${HTTP_SUCCESS}" == "True" || "${HTTP_SUCCESS}" == "true" ]]; then
  RULESET_ID=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null)
  VERSION=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['version'])" 2>/dev/null)
  RULE_COUNT=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['result']['rules']))" 2>/dev/null)
  printf '\n'
  printf '%s\n' "✓ Rate limit rules provisioned"
  printf '%s\n' "  Ruleset:  ${RULESET_ID}"
  printf '%s\n' "  Version:  ${VERSION}"
  printf '%s\n' "  Rules:    ${RULE_COUNT} total (1 health + ${NON_HEALTH_COUNT} preserved)"
  printf '\n'
  printf '%s\n' "  Health rate limit:"
  printf '%s\n' "  - 20 req/60s per IP — /-/health, /-/liveness, /-/readiness"
  printf '%s\n' "  - Block for 60s when exceeded"
else
  printf '\n'
  printf '%s\n' "✗ API call failed:"
  printf '%s\n' "${RESPONSE}" | python3 -m json.tool 2>/dev/null || printf '%s\n' "${RESPONSE}"
  exit 1
fi

trap - ERR
