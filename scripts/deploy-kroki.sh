#!/usr/bin/env bash
set -euo pipefail

# ─── Deploy Kroki Stack ─────────────────────────────────────────────────────
# Copies the Kroki Docker Compose stack to the target host and starts it.
# Deploys to /opt/stacks/kroki/ on the remote host.
#
# Target host is read from .env:
#   KROKI_HOST  — dedicated Kroki host (e.g., "root@10.1.1.100")
#   LXC_HOST    — fallback: the GitLab LXC itself
#
# Usage:
#   ./scripts/deploy-kroki.sh [--dry-run]
#
# Requires: SSH access to the target host, Docker + Compose installed.
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help)
      printf 'Usage: %s [--dry-run]\n\n' "$0"
      printf 'Reads KROKI_HOST (or LXC_HOST) from .env to determine the deploy target.\n'
      exit 0
      ;;
    *)
      printf '✗ Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n✗ Deploy failed at line %s.\n" "${LINENO}"' ERR

# ─── Resolve paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${REPO_ROOT}/stacks/kroki"
REMOTE_DIR="/opt/stacks/kroki"
ENV_FILE="${REPO_ROOT}/.env"

SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=30 -o BatchMode=yes)

# ─── Load .env ───────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  printf '✗ Missing %s. Copy .env.example and fill in real values.\n' "${ENV_FILE}"
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# ─── Resolve target host ────────────────────────────────────────────────────
# KROKI_HOST takes priority; falls back to LXC_HOST (GitLab server)
TARGET_HOST="${KROKI_HOST:-${LXC_HOST:-}}"

if [[ -z "${TARGET_HOST}" ]]; then
  printf '✗ Neither KROKI_HOST nor LXC_HOST is set in .env\n'
  exit 1
fi

# Strip "root@" prefix if present — we add it ourselves
TARGET_HOST="${TARGET_HOST#root@}"

printf '── Deploying Kroki to %s ──\n\n' "${TARGET_HOST}"

# ─── Validate local files ───────────────────────────────────────────────────
for f in "${STACK_DIR}/compose.yaml" "${STACK_DIR}/.env.example"; do
  if [[ ! -f "${f}" ]]; then
    printf '✗ Missing %s\n' "${f}"
    exit 1
  fi
done
printf '✓ Local stack files found\n'

if ${DRY_RUN}; then
  printf '\n── DRY RUN (no changes will be made) ──\n\n'
fi

# ─── 1. Test SSH ─────────────────────────────────────────────────────────────
printf '→ Testing SSH to %s...\n' "${TARGET_HOST}"
if ! ssh -o ConnectTimeout=5 "root@${TARGET_HOST}" 'true' 2>/dev/null; then
  printf '✗ Cannot reach root@%s via SSH\n' "${TARGET_HOST}"
  exit 1
fi
printf '✓ SSH connected\n'

# ─── 2. Verify Docker + Compose ─────────────────────────────────────────────
printf '→ Checking Docker...\n'
DOCKER_VER=$(ssh "${SSH_OPTS[@]}" "root@${TARGET_HOST}" 'docker --version 2>/dev/null' || true)
COMPOSE_VER=$(ssh "${SSH_OPTS[@]}" "root@${TARGET_HOST}" 'docker compose version 2>/dev/null' || true)

if [[ -z "${DOCKER_VER}" ]]; then
  printf '✗ Docker is not installed on %s\n' "${TARGET_HOST}"
  printf '  Install Docker first: https://docs.docker.com/engine/install/debian/\n'
  exit 1
fi

if [[ -z "${COMPOSE_VER}" ]]; then
  printf '✗ Docker Compose plugin not found on %s\n' "${TARGET_HOST}"
  printf '  Install: apt-get install docker-compose-plugin\n'
  exit 1
fi

printf '✓ %s\n' "${DOCKER_VER}"
printf '✓ %s\n' "${COMPOSE_VER}"

# ─── 3. Create remote directory ─────────────────────────────────────────────
printf '→ Creating %s on %s...\n' "${REMOTE_DIR}" "${TARGET_HOST}"
if ${DRY_RUN}; then
  printf '  [DRY RUN] Would create %s\n' "${REMOTE_DIR}"
else
  # shellcheck disable=SC2029  # intentional client-side expansion of REMOTE_DIR
  ssh "${SSH_OPTS[@]}" "root@${TARGET_HOST}" "mkdir -p ${REMOTE_DIR}"
fi
printf '✓ Directory ready\n'

# ─── 4. Copy stack files ────────────────────────────────────────────────────
printf '→ Copying stack files...\n'
if ${DRY_RUN}; then
  printf '  [DRY RUN] Would copy compose.yaml and .env.example to %s\n' "${REMOTE_DIR}"
else
  scp "${SSH_OPTS[@]}" \
    "${STACK_DIR}/compose.yaml" \
    "root@${TARGET_HOST}:${REMOTE_DIR}/compose.yaml"

  # Only copy .env.example as .env if .env doesn't already exist
  # shellcheck disable=SC2029
  REMOTE_ENV_EXISTS=$(ssh "${SSH_OPTS[@]}" "root@${TARGET_HOST}" \
    "test -f ${REMOTE_DIR}/.env && echo yes || echo no")

  if [[ "${REMOTE_ENV_EXISTS}" == "no" ]]; then
    scp "${SSH_OPTS[@]}" \
      "${STACK_DIR}/.env.example" \
      "root@${TARGET_HOST}:${REMOTE_DIR}/.env"
    printf '  .env created from .env.example\n'
  else
    printf '  .env already exists, skipping (update manually if needed)\n'
  fi
fi
printf '✓ Files deployed\n'

# ─── 5. Start / update stack ────────────────────────────────────────────────
printf '→ Starting Kroki stack...\n'
if ${DRY_RUN}; then
  printf '  [DRY RUN] Would run: docker compose up -d\n'
else
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "root@${TARGET_HOST}" \
    "cd ${REMOTE_DIR} && docker compose up -d"
fi
printf '✓ Stack started\n'

# ─── 6. Health check ────────────────────────────────────────────────────────
if ! ${DRY_RUN}; then
  printf '→ Waiting for health check...\n'
  ATTEMPTS=0
  while [[ ${ATTEMPTS} -lt 10 ]]; do
    sleep 3
    ATTEMPTS=$((ATTEMPTS + 1))
    HTTP_CODE=$(ssh "${SSH_OPTS[@]}" "root@${TARGET_HOST}" \
      "curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" == "200" ]]; then
      printf '✓ Kroki healthy (HTTP 200)\n'
      break
    fi
    printf '  Attempt %s/10 (HTTP %s)...\n' "${ATTEMPTS}" "${HTTP_CODE}"
  done

  if [[ "${HTTP_CODE}" != "200" ]]; then
    printf '⚠ Kroki did not become healthy within 30 seconds\n'
    printf '  Check: ssh root@%s "cd %s && docker compose logs"\n' "${TARGET_HOST}" "${REMOTE_DIR}"
    exit 1
  fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────
printf '\n✓ Kroki deployed to %s\n' "${TARGET_HOST}"
printf '  URL: http://%s:8000\n' "${TARGET_HOST}"
printf '  Compose: %s\n' "${REMOTE_DIR}"
printf '\n'
printf '  To wire into GitLab:\n'
printf '    gitlab-rails runner "s = Gitlab::CurrentSettings.current_application_settings; s.kroki_enabled = true; s.kroki_url = '"'"'http://%s:8000'"'"'; s.save!"\n' "${TARGET_HOST}"
