#!/usr/bin/env bash
set -euo pipefail

# ─── Generate wrangler.jsonc from .env ───────────────────────────────────────
# Reads CDN_DOMAIN, CDN_WORKER_NAME, and VPC_SERVICE_ID from the parent .env
# and writes a fully populated wrangler.jsonc for the CDN Worker.
#
# Usage:
#   ./generate-wrangler.sh              # write wrangler.jsonc
#   ./generate-wrangler.sh --dry-run    # preview without writing
#
# Requires: CDN_DOMAIN + VPC_SERVICE_ID in ../.env
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "ERROR: generate-wrangler.sh failed at line ${LINENO}."' ERR

# ─── Load .env ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
else
  printf '%s\n' "ERROR: ${ENV_FILE} not found. Copy .env.example to .env and fill in your values."
  exit 1
fi

# ─── Validate required variables ─────────────────────────────────────────────
for var in CDN_DOMAIN VPC_SERVICE_ID; do
  if [[ -z "${!var:-}" || "${!var}" == "<"* ]]; then
    printf '%s\n' "ERROR: ${var} is missing or still a placeholder in .env"
    exit 1
  fi
done

# Default worker name if not set
CDN_WORKER_NAME="${CDN_WORKER_NAME:-cdn-gitlab}"

# ─── Generate wrangler.jsonc ─────────────────────────────────────────────────
OUTPUT_FILE="${SCRIPT_DIR}/wrangler.jsonc"

CONFIG=$(
  cat <<EOF
{
  "\$schema": "node_modules/wrangler/config-schema.json",
  "name": "${CDN_WORKER_NAME}",
  "main": "src/index.ts",
  "compatibility_date": "2026-02-28",
  "placement": {
    "mode": "smart"
  },
  "routes": [
    {
      "pattern": "${CDN_DOMAIN}",
      "custom_domain": true
    }
  ],
  "vpc_services": [
    {
      "binding": "GITLAB",
      "service_id": "${VPC_SERVICE_ID}",
      "remote": true
    }
  ],
  "analytics_engine_datasets": [
    {
      "binding": "ANALYTICS",
      "dataset": "gitlab_cdn"
    }
  ],
  "logpush": true,
  "observability": {
    "enabled": false,
    "head_sampling_rate": 1,
    "logs": {
      "enabled": true,
      "head_sampling_rate": 1,
      "persist": true,
      "invocation_logs": true
    },
    "traces": {
      "enabled": false,
      "persist": true,
      "head_sampling_rate": 1
    }
  }
}
EOF
)

if [[ "${DRY_RUN}" == "true" ]]; then
  printf '%s\n' "[DRY RUN] Would write ${OUTPUT_FILE}:"
  printf '\n'
  printf '%s\n' "${CONFIG}"
else
  printf '%s\n' "${CONFIG}" >"${OUTPUT_FILE}"
  printf '%s\n' "Wrote ${OUTPUT_FILE}"
  printf '%s\n' "  name:       ${CDN_WORKER_NAME}"
  printf '%s\n' "  route:      ${CDN_DOMAIN}"
  printf '%s\n' "  service_id: ${VPC_SERVICE_ID}"
fi
