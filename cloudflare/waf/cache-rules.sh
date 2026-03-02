#!/usr/bin/env bash
set -euo pipefail

# ─── CDN Cache Rule Provisioning ─────────────────────────────────────────────
# Creates/updates cache rules for the GitLab CDN Worker on Cloudflare.
# Uses read-merge-write to preserve non-CDN cache rules in the same phase.
#
# Usage:
#   ./cache-rules.sh              # provision rules
#   ./cache-rules.sh --dry-run    # show what would be created
#
# Requires: CF_ZONE_ID + CDN_DOMAIN in .env
#           CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL in shell env (Global API key)
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Cache rule provisioning failed at line ${LINENO}."' ERR

# ─── Check required commands ─────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  printf '%s\n' "✗ python3 is required but not found"
  exit 1
fi

# ─── Load .env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

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
for var in CF_ZONE_ID CDN_DOMAIN; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "✗ Missing ${var} — set it in .env"
    exit 1
  fi
done

ZONE_ID="${CF_ZONE_ID}"
CDN="${CDN_DOMAIN}"
NON_CDN_COUNT=0
API_BASE="https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/rulesets"

printf '%s\n' "── CDN Cache Rules for ${CDN} (zone: ${ZONE_ID}) ──"
printf '\n'

# ─── Find existing cache settings ruleset ─────────────────────────────────────
printf '%s\n' "→ Reading existing cache rules..."
EXISTING_ID=$(curl -s \
  "${AUTH_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  "${API_BASE}" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('result', []):
    if r.get('phase') == 'http_request_cache_settings' and r.get('kind') == 'zone':
        print(r['id'])
        break
" 2>/dev/null || true)

# ─── Read existing rules and filter out CDN ones ─────────────────────────────
NON_CDN_RULES="[]"
if [[ -n "${EXISTING_ID}" ]]; then
  printf '%s\n' "  Found existing ruleset: ${EXISTING_ID}"
  NON_CDN_RULES=$(curl -s \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    "${API_BASE}/${EXISTING_ID}" \
    | CDN="${CDN}" python3 -c "
import json, sys, os
data = json.load(sys.stdin)
rules = data.get('result', {}).get('rules', [])
# Keep rules that do NOT reference the CDN domain
cdn = os.environ['CDN']
non_cdn = [r for r in rules if cdn not in r.get('expression', '')]
# Strip read-only fields that can't be sent back
for r in non_cdn:
    for key in ['id', 'ref', 'version', 'last_updated']:
        r.pop(key, None)
print(json.dumps(non_cdn))
" 2>/dev/null)
  NON_CDN_COUNT=$(printf '%s\n' "${NON_CDN_RULES}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  printf '%s\n' "  Found ${NON_CDN_COUNT} non-CDN rules to preserve"
else
  printf '%s\n' "  No existing cache ruleset found"
fi

# ─── Build the CDN cache rules ───────────────────────────────────────────────
CDN_RULES=$(
  cat <<JSON
[
  {
    "action": "set_cache_settings",
    "action_parameters": {
      "browser_ttl": {
        "default": 3600,
        "mode": "override_origin"
      },
      "cache": true,
      "cache_key": {
        "custom_key": {
          "host": {
            "resolved": false
          },
          "query_string": {
            "include": ["inline", "append_sha", "path"]
          }
        }
      },
      "edge_ttl": {
        "default": 86400,
        "mode": "override_origin"
      }
    },
    "description": "GitLab CDN — cache public static objects",
    "enabled": true,
    "expression": "(http.host eq \"${CDN}\" and http.request.method in {\"GET\" \"HEAD\"} and (http.request.uri.path contains \"/raw/\" or http.request.uri.path contains \"/-/archive/\") and not http.request.uri.query contains \"token=\")"
  },
  {
    "action": "set_cache_settings",
    "action_parameters": {
      "browser_ttl": {
        "mode": "bypass"
      },
      "cache": false
    },
    "description": "GitLab CDN — bypass cache for authenticated requests",
    "enabled": true,
    "expression": "(http.host eq \"${CDN}\" and http.request.uri.query contains \"token=\")"
  }
]
JSON
)

# ─── Merge CDN rules + non-CDN rules ─────────────────────────────────────────
MERGED_RULES=$(CDN_JSON="${CDN_RULES}" NON_CDN_JSON="${NON_CDN_RULES}" python3 -c "
import json, os
cdn = json.loads(os.environ['CDN_JSON'])
non_cdn = json.loads(os.environ['NON_CDN_JSON'])
print(json.dumps(cdn + non_cdn))
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
PAYLOAD="{\"rules\": ${MERGED_RULES}}"

if [[ -n "${EXISTING_ID}" ]]; then
  printf '%s\n' "→ Updating cache ruleset ${EXISTING_ID}..."
  RESPONSE=$(curl -s -X PUT \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "${API_BASE}/${EXISTING_ID}")
else
  printf '%s\n' "→ Creating new cache ruleset..."
  PAYLOAD=$(printf '%s\n' "${PAYLOAD}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['name'] = 'default'
data['kind'] = 'zone'
data['phase'] = 'http_request_cache_settings'
print(json.dumps(data))
")
  RESPONSE=$(curl -s -X POST \
    "${AUTH_HEADERS[@]}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "${API_BASE}")
fi

# ─── Check result ─────────────────────────────────────────────────────────────
HTTP_SUCCESS=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null || printf '%s\n' "false")

if [[ "${HTTP_SUCCESS}" == "True" || "${HTTP_SUCCESS}" == "true" ]]; then
  RULESET_ID=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null)
  VERSION=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['version'])" 2>/dev/null)
  RULE_COUNT=$(printf '%s\n' "${RESPONSE}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['result']['rules']))" 2>/dev/null)
  printf '\n'
  printf '%s\n' "✓ Cache rules provisioned"
  printf '%s\n' "  Ruleset:  ${RULESET_ID}"
  printf '%s\n' "  Version:  ${VERSION}"
  printf '%s\n' "  Rules:    ${RULE_COUNT} total (2 CDN + ${NON_CDN_COUNT} preserved)"
  printf '\n'
  printf '%s\n' "  CDN rules:"
  printf '%s\n' "  1. cache  — Public static objects (browser: 1h, edge: 24h)"
  printf '%s\n' "  2. bypass — Authenticated requests (?token=)"
else
  printf '\n'
  printf '%s\n' "✗ API call failed:"
  printf '%s\n' "${RESPONSE}" | python3 -m json.tool 2>/dev/null || printf '%s\n' "${RESPONSE}"
  exit 1
fi

trap - ERR
