#!/usr/bin/env bash
set -euo pipefail

# ─── Deploy External GitLab Runner ────────────────────────────────────────────
# Local orchestrator: pushes config + scripts to a dedicated runner LXC,
# then executes external-runner.sh remotely.
#
# Usage:
#   ./deploy-runner.sh                    # deploy
#   ./deploy-runner.sh --dry-run          # preview
#
# Requires .env with: GITLAB_DOMAIN, ORG_NAME, ORG_URL
# Plus environment variables or arguments for the runner target.
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Deploy failed at line ${LINENO}. Check output above."' ERR

# SSH/SCP options
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o BatchMode=yes)

# ─── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf '%s\n' "✗ Missing ${ENV_FILE}"
  exit 1
fi

# ─── Load .env ────────────────────────────────────────────────────────────────
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# ─── Runner-specific config ──────────────────────────────────────────────────
# These can be overridden via environment variables before calling this script:
#   RUNNER_LXC_HOST=root@<runner-ip> RUNNER_NAME=runner-1 ./deploy-runner.sh
RUNNER_LXC_HOST="${RUNNER_LXC_HOST:-}"
RUNNER_RUNNER_NAME="${RUNNER_RUNNER_NAME:-runner-1}"
RUNNER_RUNNER_TAGS="${RUNNER_RUNNER_TAGS:-linux,x64}"
RUNNER_SSH_ALLOW_CIDR="${RUNNER_SSH_ALLOW_CIDR:-${SSH_ALLOW_CIDR:-10.0.0.0/8}}"
RUNNER_GITLAB_PAT="${RUNNER_GITLAB_PAT:-}"

if [[ -z "${RUNNER_LXC_HOST}" ]]; then
  printf '%s\n' "✗ RUNNER_LXC_HOST not set. Usage:"
  printf '%s\n' "  RUNNER_LXC_HOST=root@<runner-ip> ./deploy-runner.sh"
  exit 1
fi

if [[ -z "${RUNNER_GITLAB_PAT}" ]]; then
  printf '%s\n' "✗ RUNNER_GITLAB_PAT not set. Provide a Personal Access Token with create_runner scope."
  printf '%s\n' "  RUNNER_GITLAB_PAT=glpat-... RUNNER_LXC_HOST=root@<runner-ip> ./deploy-runner.sh"
  exit 1
fi

# ─── Validate required variables from .env ────────────────────────────────────
for var in GITLAB_DOMAIN ORG_NAME ORG_URL; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "✗ Missing ${var} in .env"
    exit 1
  fi
done

# ─── Verify local files exist ────────────────────────────────────────────────
for f in "${SCRIPT_DIR}/external-runner.sh" "${SCRIPT_DIR}/runner-apps.sh" "${SCRIPT_DIR}/runner-apps.json" "${REPO_ROOT}/config/banner.txt"; do
  if [[ ! -f "${f}" ]]; then
    printf '%s\n' "✗ Missing ${f}"
    exit 1
  fi
done

printf '%s\n' "── Deploying External Runner to ${RUNNER_LXC_HOST} ──"
printf '\n'

# ─── Test SSH ─────────────────────────────────────────────────────────────────
printf '%s\n' "→ Testing SSH connection..."
if ! ssh -o ConnectTimeout=5 "${RUNNER_LXC_HOST}" 'true' 2>/dev/null; then
  printf '%s\n' "✗ Cannot reach ${RUNNER_LXC_HOST} via SSH."
  exit 1
fi
printf '%s\n' "✓ SSH connected"
printf '%s\n' "✓ All local files present"

if ${DRY_RUN}; then
  printf '\n'
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  Target:       ${RUNNER_LXC_HOST}"
  printf '%s\n' "  GitLab:       https://${GITLAB_DOMAIN}"
  printf '%s\n' "  Runner name:  ${RUNNER_RUNNER_NAME}"
  printf '%s\n' "  Runner tags:  ${RUNNER_RUNNER_TAGS}"
  printf '%s\n' "  SSH allow:    ${RUNNER_SSH_ALLOW_CIDR}"
  printf '%s\n' "  Org:          ${ORG_NAME} — ${ORG_URL}"
  printf '%s\n' "  PAT:          ${RUNNER_GITLAB_PAT:0:8}...(redacted)"
  printf '\n'
  printf '%s\n' "  Would deploy:"
  printf '%s\n' "    /root/.secrets/runner.env"
  printf '%s\n' "    /tmp/external-runner.sh"
  printf '%s\n' "    /tmp/runner-apps.sh"
  printf '%s\n' "    /tmp/runner-apps.json"
  printf '%s\n' "    /tmp/runner-banner.txt"
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to deploy."
  exit 0
fi

# ─── Push secrets ─────────────────────────────────────────────────────────────
printf '%s\n' "→ Creating /root/.secrets on runner LXC..."
ssh "${SSH_OPTS[@]}" "${RUNNER_LXC_HOST}" 'mkdir -p /root/.secrets && chmod 700 /root/.secrets'

printf '%s\n' "→ Building runner.env..."
TMPDIR_SECRETS="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR_SECRETS}" 2>/dev/null; }
trap 'cleanup; printf "\n"; printf "%s\n" "✗ Deploy failed at line ${LINENO}."' ERR
trap cleanup EXIT

_env() { printf '%s=%q\n' "$1" "$2"; }
{
  _env GITLAB_DOMAIN      "${GITLAB_DOMAIN}"
  _env GITLAB_PAT         "${RUNNER_GITLAB_PAT}"
  _env RUNNER_NAME        "${RUNNER_RUNNER_NAME}"
  _env RUNNER_TAGS        "${RUNNER_RUNNER_TAGS}"
  _env SSH_ALLOW_CIDR     "${RUNNER_SSH_ALLOW_CIDR}"
  _env ORG_NAME           "${ORG_NAME}"
  _env ORG_URL            "${ORG_URL}"
} > "${TMPDIR_SECRETS}/runner.env"

scp -q "${SSH_OPTS[@]}" "${TMPDIR_SECRETS}/runner.env" "${RUNNER_LXC_HOST}:/root/.secrets/runner.env"
ssh "${SSH_OPTS[@]}" "${RUNNER_LXC_HOST}" 'chmod 600 /root/.secrets/runner.env'
printf '%s\n' "✓ Secrets deployed"

# ─── Push scripts ─────────────────────────────────────────────────────────────
printf '%s\n' "→ Copying scripts to runner LXC..."
scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}/external-runner.sh"  "${RUNNER_LXC_HOST}:/tmp/external-runner.sh"
scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}/runner-apps.sh"      "${RUNNER_LXC_HOST}:/tmp/runner-apps.sh"
scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}/runner-apps.json"    "${RUNNER_LXC_HOST}:/tmp/runner-apps.json"
scp -q "${SSH_OPTS[@]}" "${REPO_ROOT}/config/banner.txt"    "${RUNNER_LXC_HOST}:/tmp/runner-banner.txt"
ssh "${SSH_OPTS[@]}" "${RUNNER_LXC_HOST}" 'chmod +x /tmp/external-runner.sh /tmp/runner-apps.sh'
printf '%s\n' "✓ Scripts copied"

# ─── Run setup ────────────────────────────────────────────────────────────────
printf '\n'
printf '%s\n' "── Running setup on runner LXC ──"
printf '%s\n' "  Tip: if this disconnects, the setup continues in screen."
printf '%s\n' "  Monitor: ssh ${RUNNER_LXC_HOST} 'tail -f /root/runner-setup.log'"
printf '\n'

# Install screen if not present, then run in a screen session
ssh "${SSH_OPTS[@]}" "${RUNNER_LXC_HOST}" 'command -v screen >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq screen > /dev/null)'
ssh "${SSH_OPTS[@]}" "${RUNNER_LXC_HOST}" 'screen -dmS runner-setup bash -c "set -o pipefail; /tmp/external-runner.sh 2>&1 | tee /root/runner-setup.log; echo EXIT_CODE=\${PIPESTATUS[0]} >> /root/runner-setup.log"'
printf '%s\n' "✓ Setup launched in screen session 'runner-setup'"
printf '\n'

# Tail the log until done
printf '%s\n' "── Live output ──"
printf '\n'
# Poll until EXIT_CODE appears in the log (setup finished)
while true; do
  if ssh -o ConnectTimeout=5 "${RUNNER_LXC_HOST}" 'test -f /root/runner-setup.log' 2>/dev/null; then
    break
  fi
  sleep 1
done

# Stream output, exit when we see EXIT_CODE
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "${RUNNER_LXC_HOST}" \
  'tail -f /root/runner-setup.log' &
TAIL_PID=$!

# Wait for completion
while true; do
  if ssh -o ConnectTimeout=5 "${RUNNER_LXC_HOST}" 'grep -q "^EXIT_CODE=" /root/runner-setup.log' 2>/dev/null; then
    sleep 2
    kill "${TAIL_PID}" 2>/dev/null || true
    wait "${TAIL_PID}" 2>/dev/null || true
    break
  fi
  sleep 5
done

# Check exit code
EXIT_CODE=$(ssh "${RUNNER_LXC_HOST}" 'grep "^EXIT_CODE=" /root/runner-setup.log | cut -d= -f2')
printf '\n'
if [[ "${EXIT_CODE}" == "0" ]]; then
  printf '%s\n' "✓ External runner deploy complete!"
else
  printf '%s\n' "✗ Setup failed on the runner LXC. Check: ssh ${RUNNER_LXC_HOST} 'cat /root/runner-setup.log'"
  exit 1
fi
