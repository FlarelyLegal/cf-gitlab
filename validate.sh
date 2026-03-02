#!/usr/bin/env bash
set -euo pipefail

# ─── Validation Script ───────────────────────────────────────────────────────
# Validates the deployed GitLab environment — .env configuration, SSH
# connectivity, Cloudflare DNS/R2/OIDC resources. Read-only, no changes made.
#
# Usage:
#   ./validate.sh
#
# Checks:
#   1. Local: .env exists, all required variables set, no placeholders
#   2. SSH:   LXC is reachable
#   3. Files: all scripts/configs present locally
#   4. Cloudflare API: credentials valid, zone exists
#   5. DNS: records exist for all domains (with proxy status)
#   6. R2: all 10 buckets exist
#   7. Access: OIDC issuer responds
#   8. HTTPS: GitLab health endpoint reachable via tunnel
#
# Auth: requires CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL in shell environment
#       (Global API key — set in your shell profile, NOT in .env).
# ──────────────────────────────────────────────────────────────────────────────

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Validation failed unexpectedly at line ${LINENO}."' ERR

# ─── Check required commands ─────────────────────────────────────────────────
for cmd in curl ssh python3; do
  if ! command -v "${cmd}" &>/dev/null; then
    printf '%s\n' "✗ Required command '${cmd}' not found"
    exit 1
  fi
done

PASS=0
WARN=0
FAIL=0

pass() { printf '%s\n' "  ✓ $1"; ((PASS++)) || true; }
warn() { printf '%s\n' "  ⚠ $1"; ((WARN++)) || true; }
fail() { printf '%s\n' "  ✗ $1"; ((FAIL++)) || true; }

# ─── Resolve paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

printf '%s\n' "── Validate GitLab Setup ──"
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 1. Local Configuration ──"

if [[ ! -f "${ENV_FILE}" ]]; then
  fail ".env not found — copy .env.example and fill in values"
  printf '\n'
  printf '%s\n' "Cannot continue without .env. Exiting."
  exit 1
fi
pass ".env exists"

# Source .env — disable set -e temporarily in case .env has issues
set +e
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
SOURCE_RC=$?
set +a
set -e

if [[ ${SOURCE_RC} -ne 0 ]]; then
  fail ".env failed to source (syntax error?) �� fix and retry"
  exit 1
fi

REQUIRED_VARS=(
  LXC_HOST GITLAB_DOMAIN GITLAB_ROOT_EMAIL GITLAB_ROOT_PASSWORD ORG_NAME ORG_URL
  CF_API_TOKEN CERT_EMAIL REGISTRY_DOMAIN PAGES_DOMAIN INTERNAL_DNS SSH_ALLOW_CIDR
  TIMEZONE OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET GITHUB_APP_ID GITHUB_APP_SECRET
  R2_ENDPOINT R2_ACCESS_KEY R2_SECRET_KEY R2_BUCKET_PREFIX RUNNER_NAME RUNNER_TAGS
)

MISSING_VARS=()
PLACEHOLDER_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
  val="${!var:-}"
  if [[ -z "${val}" ]]; then
    MISSING_VARS+=("${var}")
  elif [[ "${val}" == *"<"*">"* ]]; then
    PLACEHOLDER_VARS+=("${var}")
  fi
done

if [[ ${#MISSING_VARS[@]} -eq 0 ]]; then
  pass "All ${#REQUIRED_VARS[@]} required variables set"
else
  fail "Missing variables: ${MISSING_VARS[*]}"
fi

if [[ ${#PLACEHOLDER_VARS[@]} -gt 0 ]]; then
  fail "Placeholder values detected: ${PLACEHOLDER_VARS[*]}"
fi

# Optional vars — Cloudflare API scripts
for var in CF_ZONE_ID CDN_DOMAIN; do
  if [[ -z "${!var:-}" ]]; then
    warn "${var} not set (needed for cloudflare/waf-rules.sh / cloudflare/cache-rules.sh)"
  else
    pass "${var} set"
  fi
done

# Optional vars — CDN Worker
for var in VPC_SERVICE_ID CDN_WORKER_NAME; do
  if [[ -z "${!var:-}" ]]; then
    warn "${var} not set (needed for generate-wrangler.sh)"
  else
    pass "${var} set"
  fi
done

# Password strength (only check if password is present and not a placeholder)
if [[ -n "${GITLAB_ROOT_PASSWORD:-}" && "${GITLAB_ROOT_PASSWORD}" != *"<"*">"* ]]; then
  if [[ ${#GITLAB_ROOT_PASSWORD} -lt 12 ]]; then
    warn "GITLAB_ROOT_PASSWORD is shorter than 12 chars (will be auto-generated during install)"
  else
    pass "GITLAB_ROOT_PASSWORD is 12+ chars"
  fi
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 2. SSH Connectivity ──"

if ssh -o ConnectTimeout=5 -o BatchMode=yes "${LXC_HOST}" 'true' 2>/dev/null; then
  pass "SSH to ${LXC_HOST}"
  OS_INFO=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${LXC_HOST}" 'grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d \"' 2>/dev/null || printf '%s\n' "unknown")
  pass "Remote OS: ${OS_INFO}"
else
  fail "Cannot SSH to ${LXC_HOST}"
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 3. Local Files ──"

LOCAL_FILES=(setup.sh motd.sh config/banner.txt cloudflare/cloudflare-timing.sh config/chrony.conf)
for f in "${LOCAL_FILES[@]}"; do
  if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
    pass "${f}"
  else
    fail "${f} missing"
  fi
done
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 4. Cloudflare API ──"

# Uses Global API key from shell env (CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL).
# These must be set in your shell profile — they are NOT in .env.
if [[ -z "${CLOUDFLARE_API_KEY:-}" || -z "${CLOUDFLARE_EMAIL:-}" ]]; then
  fail "Missing CLOUDFLARE_API_KEY or CLOUDFLARE_EMAIL in environment"
  printf '\n'
  printf '%s\n' "Skipping Cloudflare checks (no credentials)."
  printf '\n'
  # Skip to results
  printf '%s\n' "══════════════════════════════════════════════════════"
  printf '%s\n' "  Results:  ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
  printf '%s\n' "══════════════════════════════════════════════════════"
  printf '\n'
  printf '%s\n' "  Some checks failed — review the issues above."
  exit 1
fi
CF_AUTH=(-H "X-Auth-Key: ${CLOUDFLARE_API_KEY}" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL}")

# Use CLOUDFLARE_ACCOUNT_ID from shell if available
CF_ACCT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"

CF_API="https://api.cloudflare.com/client/v4"

# Verify API access via zone listing
ZONE_TEST=$(curl -s --connect-timeout 10 --max-time 30 "${CF_AUTH[@]}" "${CF_API}/zones?per_page=1" 2>/dev/null || printf '')
if [[ -z "${ZONE_TEST}" ]]; then
  fail "Cloudflare API unreachable (network error or timeout)"
else
  ZONE_TEST_OK=$(printf '%s\n' "${ZONE_TEST}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || printf '%s\n' "false")
  if [[ "${ZONE_TEST_OK}" == "True" || "${ZONE_TEST_OK}" == "true" ]]; then
    pass "Global API key is valid (${CLOUDFLARE_EMAIL})"
  else
    fail "Cloudflare API credentials are invalid or have no zone permissions"
  fi
fi

# Verify zone
if [[ -n "${CF_ZONE_ID:-}" ]]; then
  ZONE_CHECK=$(curl -s --connect-timeout 10 --max-time 30 "${CF_AUTH[@]}" "${CF_API}/zones/${CF_ZONE_ID}" 2>/dev/null || printf '')
  if [[ -n "${ZONE_CHECK}" ]]; then
    ZONE_NAME=$(printf '%s\n' "${ZONE_CHECK}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('name',''))" 2>/dev/null || printf '')
    if [[ -n "${ZONE_NAME}" ]]; then
      pass "Zone ${CF_ZONE_ID} → ${ZONE_NAME}"
    else
      fail "Zone ${CF_ZONE_ID} not found or no access"
    fi
  else
    fail "Zone lookup failed (network error)"
  fi
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 5. DNS Records ──"

if [[ -n "${CF_ZONE_ID:-}" ]]; then
  check_dns() {
    local name="$1"
    local encoded_name="${name//\*/%2A}"
    local result
    result=$(curl -s --connect-timeout 10 --max-time 30 "${CF_AUTH[@]}" \
      "${CF_API}/zones/${CF_ZONE_ID}/dns_records?name=${encoded_name}" 2>/dev/null || printf '')
    if [[ -z "${result}" ]]; then
      fail "${name} — API request failed"
      return
    fi
    local count
    count=$(printf '%s\n' "${result}" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('result',[])))" 2>/dev/null || printf '%s\n' "0")
    if [[ "${count}" -gt 0 ]]; then
      local rtype proxied proxy_label
      rtype=$(printf '%s\n' "${result}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['type'])" 2>/dev/null)
      proxied=$(printf '%s\n' "${result}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0].get('proxied', False))" 2>/dev/null)
      if [[ "${proxied}" == "True" ]]; then
        proxy_label="proxied"
      else
        proxy_label="DNS-only"
      fi
      pass "${name} (${rtype}, ${proxy_label})"
      # Warn if a tunnel CNAME is DNS-only (should be proxied for tunnel to work)
      if [[ "${rtype}" == "CNAME" && "${proxy_label}" == "DNS-only" ]]; then
        warn "  ↳ ${name} is DNS-only — Cloudflare Tunnel requires proxied (orange cloud)"
      fi
    else
      fail "${name} — no DNS record found"
    fi
  }

  check_dns "${GITLAB_DOMAIN}"
  check_dns "${REGISTRY_DOMAIN}"
  check_dns "${PAGES_DOMAIN}"

  # Check for SSH subdomain
  SSH_DOMAIN="ssh.${GITLAB_DOMAIN}"
  check_dns "${SSH_DOMAIN}"

  # Wildcard for pages
  check_dns "*.${PAGES_DOMAIN}"

  # CDN (optional)
  if [[ -n "${CDN_DOMAIN:-}" ]]; then
    check_dns "${CDN_DOMAIN}"
  fi
else
  warn "Skipping DNS checks — CF_ZONE_ID not set"
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 6. R2 Buckets ──"

# Resolve account ID: prefer R2_ENDPOINT (always matches the correct account),
# fall back to CLOUDFLARE_ACCOUNT_ID from shell env
R2_ACCT=$(printf '%s\n' "${R2_ENDPOINT:-}" | sed -n 's|^https://\([^.]*\)\.r2\.cloudflarestorage\.com.*|\1|p')
if [[ -z "${R2_ACCT}" ]]; then
  R2_ACCT="${CF_ACCT_ID:-}"
  if [[ -z "${R2_ACCT}" ]]; then
    warn "Cannot determine account ID — set CLOUDFLARE_ACCOUNT_ID in your shell or R2_ENDPOINT in .env"
    warn "R2 bucket check skipped"
    R2_ACCT=""
  fi
fi

BUCKET_SUFFIXES=(artifacts external-diffs lfs uploads packages dependency-proxy terraform-state pages ci-secure-files)

if [[ -n "${R2_ACCT}" ]]; then
  # List all buckets once (uses CF_AUTH — Global API key has Account-level R2 perms)
  R2_BUCKETS=$(curl -s --connect-timeout 10 --max-time 30 "${CF_AUTH[@]}" \
    "${CF_API}/accounts/${R2_ACCT}/r2/buckets?per_page=100" 2>/dev/null || printf '')
  BUCKET_LIST=$(printf '%s\n' "${R2_BUCKETS}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data.get('result', {}).get('buckets', []):
    print(b['name'])
" 2>/dev/null || printf '')

  if [[ -z "${BUCKET_LIST}" ]]; then
    # Try to check if it's a permissions issue or just empty
    R2_SUCCESS=$(printf '%s\n' "${R2_BUCKETS}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || printf '%s\n' "false")
    if [[ "${R2_SUCCESS}" != "True" && "${R2_SUCCESS}" != "true" ]]; then
      warn "Cannot list R2 buckets — no API credentials with Account-level R2 permissions"
      warn "Buckets can still work if they exist (S3 API uses separate R2 credentials)"
    fi
  else
    for suffix in "${BUCKET_SUFFIXES[@]}"; do
      BUCKET_NAME="${R2_BUCKET_PREFIX}-${suffix}"
      if printf '%s\n' "${BUCKET_LIST}" | grep -qx "${BUCKET_NAME}"; then
        pass "${BUCKET_NAME}"
      else
        fail "${BUCKET_NAME} — bucket not found"
      fi
    done

    # Check backup bucket (uses R2_BACKUP_BUCKET or default)
    BACKUP_BUCKET="${R2_BACKUP_BUCKET:-${R2_BUCKET_PREFIX}-backups}"
    if printf '%s\n' "${BUCKET_LIST}" | grep -qx "${BACKUP_BUCKET}"; then
      pass "${BACKUP_BUCKET} (backups)"
    else
      warn "${BACKUP_BUCKET} (backups) — bucket not found"
    fi
  fi
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 7. OIDC Issuer ──"

OIDC_STATUS=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" \
  "${OIDC_ISSUER}/.well-known/openid-configuration" 2>/dev/null || printf '%s\n' "000")

if [[ "${OIDC_STATUS}" == "200" ]]; then
  if [[ ${#OIDC_ISSUER} -gt 50 ]]; then
    pass "OIDC issuer responds (${OIDC_ISSUER:0:50}...)"
  else
    pass "OIDC issuer responds (${OIDC_ISSUER})"
  fi
elif [[ "${OIDC_STATUS}" == "000" ]]; then
  fail "OIDC issuer unreachable"
else
  warn "OIDC issuer returned HTTP ${OIDC_STATUS} (expected 200)"
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "── 8. HTTPS / Tunnel ──"

GITLAB_HEALTH=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" \
  "https://${GITLAB_DOMAIN}/-/health" 2>/dev/null || printf '%s\n' "000")

if [[ "${GITLAB_HEALTH}" == "200" ]]; then
  pass "GitLab health endpoint responds (https://${GITLAB_DOMAIN}/-/health)"
elif [[ "${GITLAB_HEALTH}" == "302" ]]; then
  pass "GitLab responds (302 redirect — likely to login)"
elif [[ "${GITLAB_HEALTH}" == "000" ]]; then
  fail "GitLab unreachable at https://${GITLAB_DOMAIN} (tunnel down?)"
else
  warn "GitLab returned HTTP ${GITLAB_HEALTH} (expected 200)"
fi
printf '\n'

# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "══════════════════════════════════════════════════════"
printf '%s\n' "  Results:  ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
printf '%s\n' "══════════════════════════════════════════════════════"

trap - ERR

if [[ ${FAIL} -gt 0 ]]; then
  printf '\n'
  printf '%s\n' "  Some checks failed — review the issues above."
  exit 1
elif [[ ${WARN} -gt 0 ]]; then
  printf '\n'
  printf '%s\n' "  All critical checks passed. Review warnings above."
  exit 0
else
  printf '\n'
  printf '%s\n' "  All checks passed. Environment is healthy."
  exit 0
fi
