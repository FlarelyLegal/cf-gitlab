#!/usr/bin/env bash
set -euo pipefail

# ─── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=false
FROM_STEP=0
SETUP_EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      SETUP_EXTRA_ARGS+=(--dry-run)
      shift
      ;;
    --from-step)
      FROM_STEP="${2:-}"
      if [[ -z "${FROM_STEP}" ]] || ! [[ "${FROM_STEP}" =~ ^[0-9]+$ ]] \
        || [[ "${FROM_STEP}" -lt 1 ]] || [[ "${FROM_STEP}" -gt 11 ]]; then
        printf 'Error: --from-step requires a number between 1 and 11.\n' >&2
        exit 1
      fi
      SETUP_EXTRA_ARGS+=(--from-step "${FROM_STEP}")
      shift 2
      ;;
    --reset)
      SETUP_EXTRA_ARGS+=(--reset)
      shift
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

if ${DRY_RUN}; then
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Deploy failed at line ${LINENO}. Check output above for details."' ERR

# SSH/SCP options: prevent hangs on dropped connections
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o BatchMode=yes)

# ─── Resolve paths relative to this script ────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf '%s\n' "✗ Missing ${ENV_FILE}. Copy .env.example and fill in real values."
  exit 1
fi

# ─── Load .env ────────────────────────────────────────────────────────────────
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# ─── Validate required variables ──────────────────────────────────────────────
for var in LXC_HOST GITLAB_DOMAIN GITLAB_ROOT_EMAIL GITLAB_ROOT_PASSWORD ORG_NAME ORG_URL \
  CF_API_TOKEN CERT_EMAIL REGISTRY_DOMAIN PAGES_DOMAIN INTERNAL_DNS SSH_ALLOW_CIDR \
  TZ OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET GITHUB_APP_ID GITHUB_APP_SECRET \
  R2_ENDPOINT R2_ACCESS_KEY R2_SECRET_KEY R2_BUCKET_PREFIX RUNNER_NAME RUNNER_TAGS; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "✗ Missing ${var} in .env"
    exit 1
  fi
done

# Warn about optional CDN variables (needed by cloudflare/ scripts, not by deploy)
for var in CF_ZONE_ID CDN_DOMAIN; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "⚠ ${var} not set. cloudflare/waf/waf-rules.sh and cloudflare/waf/cache-rules.sh will not work without it."
  fi
done

printf '%s\n' "── Deploying GitLab setup to ${LXC_HOST} ──"
printf '\n'

# ─── 1. Test SSH ──��───────────────────────────────────────────────────────────
printf '%s\n' "→ Testing SSH connection..."
if ! ssh -o ConnectTimeout=5 "${LXC_HOST}" 'true' 2>/dev/null; then
  printf '%s\n' "✗ Cannot reach ${LXC_HOST} via SSH. Is the LXC running?"
  exit 1
fi
printf '%s\n' "✓ SSH connected"

# ─── 2. Verify local files exist ─────────────────────────────────────────────
for f in "${SCRIPT_DIR}/setup.sh" "${SCRIPT_DIR}/motd.sh" \
  "${REPO_ROOT}/config/banner.txt" "${REPO_ROOT}/cloudflare/timing.sh" \
  "${REPO_ROOT}/config/chrony.conf"; do
  if [[ ! -f "${f}" ]]; then
    printf '%s\n' "✗ Missing ${f}"
    exit 1
  fi
done
printf '%s\n' "✓ All local files present"

if ${DRY_RUN}; then
  printf '\n'
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  Target:         ${LXC_HOST}"
  printf '%s\n' "  Domain:         ${GITLAB_DOMAIN}"
  printf '%s\n' "  Registry:       ${REGISTRY_DOMAIN}"
  printf '%s\n' "  Pages:          ${PAGES_DOMAIN}"
  printf '%s\n' "  Root email:     ${GITLAB_ROOT_EMAIL}"
  printf '%s\n' "  Cert email:     ${CERT_EMAIL}"
  printf '%s\n' "  Org:            ${ORG_NAME} / ${ORG_URL}"
  printf '%s\n' "  SSH allow:      ${SSH_ALLOW_CIDR}"
  printf '%s\n' "  Internal DNS:   ${INTERNAL_DNS}"
  printf '%s\n' "  CF API token:   ${CF_API_TOKEN:0:8}...(redacted)"
  printf '%s\n' "  OIDC issuer:    ${OIDC_ISSUER:0:40}..."
  printf '%s\n' "  GitHub app:     ${GITHUB_APP_ID}"
  printf '%s\n' "  R2 buckets:     ${R2_BUCKET_PREFIX}-{artifacts,lfs,uploads,...} (10 buckets)"
  printf '%s\n' "  Backup bucket:  ${R2_BACKUP_BUCKET:-${R2_BUCKET_PREFIX}-backups}"
  printf '%s\n' "  Runner:         ${RUNNER_NAME} (${RUNNER_TAGS})"
  printf '%s\n' "  Password:       $(printf '*%.0s' $(seq 1 ${#GITLAB_ROOT_PASSWORD}))"
  if [[ "${FROM_STEP}" -gt 0 ]]; then
    printf '%s\n' "  Resume from:    step ${FROM_STEP}"
  fi
  printf '\n'
  printf '%s\n' "  Would deploy:"
  printf '%s\n' "    /root/.secrets/gitlab.env"
  printf '%s\n' "    /root/.secrets/cloudflare.ini"
  printf '%s\n' "    /tmp/gitlab-setup.sh"
  printf '%s\n' "    /tmp/gitlab-motd.sh"
  printf '%s\n' "    /tmp/gitlab-banner.txt"
  printf '%s\n' "    /tmp/gitlab-timing.sh"
  printf '%s\n' "    /tmp/gitlab-chrony.conf"
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to deploy."
  exit 0
fi

# ─── 3. Push secrets to LXC ──────────────────────────────────────────────────
printf '%s\n' "→ Creating /root/.secrets on LXC..."
ssh "${LXC_HOST}" 'mkdir -p /root/.secrets && chmod 700 /root/.secrets'

printf '%s\n' "→ Building secrets files..."
TMPDIR_SECRETS="$(mktemp -d)"
# Clean up temp secrets on any exit (normal, error, or signal)
cleanup() { rm -rf "${TMPDIR_SECRETS}" 2>/dev/null; }
trap 'cleanup; printf "\n"; printf "%s\n" "✗ Deploy failed at line ${LINENO}. Check output above for details."' ERR
trap cleanup EXIT

_env() { printf '%s=%q\n' "$1" "$2"; }
{
  _env GITLAB_DOMAIN "${GITLAB_DOMAIN}"
  _env GITLAB_ROOT_EMAIL "${GITLAB_ROOT_EMAIL}"
  _env GITLAB_ROOT_PASSWORD "${GITLAB_ROOT_PASSWORD}"
  _env ORG_NAME "${ORG_NAME}"
  _env ORG_URL "${ORG_URL}"
  _env CERT_EMAIL "${CERT_EMAIL}"
  _env REGISTRY_DOMAIN "${REGISTRY_DOMAIN}"
  _env PAGES_DOMAIN "${PAGES_DOMAIN}"
  _env INTERNAL_DNS "${INTERNAL_DNS}"
  _env SSH_ALLOW_CIDR "${SSH_ALLOW_CIDR}"
  _env TZ "${TZ}"
  _env OIDC_ISSUER "${OIDC_ISSUER}"
  _env OIDC_CLIENT_ID "${OIDC_CLIENT_ID}"
  _env OIDC_CLIENT_SECRET "${OIDC_CLIENT_SECRET}"
  _env GITHUB_APP_ID "${GITHUB_APP_ID}"
  _env GITHUB_APP_SECRET "${GITHUB_APP_SECRET}"
  _env R2_ENDPOINT "${R2_ENDPOINT}"
  _env R2_ACCESS_KEY "${R2_ACCESS_KEY}"
  _env R2_SECRET_KEY "${R2_SECRET_KEY}"
  _env R2_BUCKET_PREFIX "${R2_BUCKET_PREFIX}"
  _env R2_BACKUP_BUCKET "${R2_BACKUP_BUCKET:-${R2_BUCKET_PREFIX}-backups}"
  _env RUNNER_NAME "${RUNNER_NAME}"
  _env RUNNER_TAGS "${RUNNER_TAGS}"
} >"${TMPDIR_SECRETS}/gitlab.env"

printf 'dns_cloudflare_api_token = %s\n' "${CF_API_TOKEN}" >"${TMPDIR_SECRETS}/cloudflare.ini"

printf '%s\n' "→ Pushing secrets to LXC..."
scp -q "${SSH_OPTS[@]}" "${TMPDIR_SECRETS}/gitlab.env" "${LXC_HOST}:/root/.secrets/gitlab.env"
scp -q "${SSH_OPTS[@]}" "${TMPDIR_SECRETS}/cloudflare.ini" "${LXC_HOST}:/root/.secrets/cloudflare.ini"
ssh "${SSH_OPTS[@]}" "${LXC_HOST}" 'chmod 600 /root/.secrets/gitlab.env /root/.secrets/cloudflare.ini'
printf '%s\n' "✓ Secrets deployed"

# ─── 4. Push scripts to LXC ──────────────────────────────────────────────────
printf '%s\n' "→ Copying scripts to LXC..."
scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}/setup.sh" "${LXC_HOST}:/tmp/gitlab-setup.sh"
scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}/motd.sh" "${LXC_HOST}:/tmp/gitlab-motd.sh"
scp -q "${SSH_OPTS[@]}" "${REPO_ROOT}/config/banner.txt" "${LXC_HOST}:/tmp/gitlab-banner.txt"
scp -q "${SSH_OPTS[@]}" "${REPO_ROOT}/cloudflare/timing.sh" "${LXC_HOST}:/tmp/gitlab-timing.sh"
scp -q "${SSH_OPTS[@]}" "${REPO_ROOT}/config/chrony.conf" "${LXC_HOST}:/tmp/gitlab-chrony.conf"
ssh "${SSH_OPTS[@]}" "${LXC_HOST}" 'chmod +x /tmp/gitlab-setup.sh /tmp/gitlab-motd.sh /tmp/gitlab-timing.sh'
printf '%s\n' "✓ Scripts copied"

# ─── 5. Run setup script ─────────────────────────────────────────────────────
printf '\n'
printf '%s\n' "── Running setup on LXC ──"
printf '\n'
if ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "${LXC_HOST}" \
  "/tmp/gitlab-setup.sh ${SETUP_EXTRA_ARGS[*]:-}"; then
  printf '\n'
  printf '%s\n' "✓ Deploy complete!"
else
  printf '\n'
  printf '%s\n' "✗ Setup script failed on the LXC."
  printf '%s\n' "  Check the output above for the step number, then retry with:"
  printf '%s\n' "  scripts/deploy.sh --from-step <N>"
  exit 1
fi
