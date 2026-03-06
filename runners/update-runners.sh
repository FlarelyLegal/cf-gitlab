#!/usr/bin/env bash
set -euo pipefail

# ─── Update Runners ──────────────────────────────────────────────────────────
# Local orchestrator that pushes runner-apps.json, runner-apps.sh, and the
# scripts/ directory to each runner LXC and executes runner-apps.sh remotely.
# Idempotent: installs missing packages and skips anything already present.
#
# Runner targets are read from .env (RUNNER_HOSTS, comma-separated) or can
# be passed as arguments.
#
# Usage:
#   ./update-runners.sh                                    # update all runners in .env
#   ./update-runners.sh root@<runner-ip>                   # update one runner
#   ./update-runners.sh root@<ip-1> root@<ip-2>           # update specific runners
#   ./update-runners.sh --dry-run                          # preview on all runners
#   ./update-runners.sh --dry-run root@<runner-ip>         # preview on one runner
#
# Requires: ssh key access to each runner as root.
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
HOSTS=()

# ─── Parse arguments ─────────────────────────────────────────────────────────
for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=true
      ;;
    *)
      HOSTS+=("${arg}")
      ;;
  esac
done

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n%s\n" "✗ Update failed at line ${LINENO}."' ERR

# ─── Resolve paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
MANIFEST="${SCRIPT_DIR}/runner-apps.json"
INSTALLER="${SCRIPT_DIR}/runner-apps.sh"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

for f in "${MANIFEST}" "${INSTALLER}"; do
  if [[ ! -f "${f}" ]]; then
    printf '%s\n' "✗ Missing ${f}"
    exit 1
  fi
done

if [[ ! -d "${SCRIPTS_DIR}" ]]; then
  printf '%s\n' "⚠ Missing ${SCRIPTS_DIR} — helper scripts will not be deployed"
fi

# ─── Resolve runner hosts ───────────────────────────────────────────────────
if [[ ${#HOSTS[@]} -eq 0 ]]; then
  # Try loading from .env
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
  fi

  if [[ -n "${RUNNER_HOSTS:-}" ]]; then
    IFS=',' read -ra HOSTS <<<"${RUNNER_HOSTS}"
  else
    printf '%s\n' "✗ No runner hosts specified."
    printf '%s\n' "  Set RUNNER_HOSTS in .env (comma-separated) or pass as arguments:"
    printf '%s\n' "  ./update-runners.sh root@<ip-1> root@<ip-2>"
    exit 1
  fi
fi

# Trim whitespace from host entries
for i in "${!HOSTS[@]}"; do
  HOSTS[i]="$(printf '%s' "${HOSTS[i]}" | xargs)"
done

SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30)

# ─── Summary ─────────────────────────────────────────────────────────────────
printf '%s\n' "── Update Runners ──"
printf '%s\n' "  Manifest: ${MANIFEST}"
printf '%s\n' "  Targets:  ${HOSTS[*]}"
if ${DRY_RUN}; then
  printf '%s\n' "  Mode:     DRY RUN"
fi
printf '\n'

# ─── Process each runner ────────────────────────────────────────────────────
TOTAL=${#HOSTS[@]}
SUCCEEDED=0
FAILED=0

for host in "${HOSTS[@]}"; do
  printf '%s\n' "════════════════════════════════════════════════════"
  printf '%s\n' "  Runner: ${host}"
  printf '%s\n' "════════════════════════════════════════════════════"
  printf '\n'

  # Test SSH connectivity
  printf '%s\n' "→ Testing SSH to ${host}..."
  if ! ssh "${SSH_OPTS[@]}" "${host}" 'true' 2>/dev/null; then
    printf '%s\n' "✗ Cannot reach ${host} via SSH. Skipping."
    printf '\n'
    FAILED=$((FAILED + 1))
    continue
  fi
  printf '%s\n' "✓ SSH connected"

  # Push manifest + installer + helper scripts
  printf '%s\n' "→ Copying manifest, installer, and helper scripts..."
  scp -q "${SSH_OPTS[@]}" "${MANIFEST}" "${host}:/tmp/runner-apps.json"
  scp -q "${SSH_OPTS[@]}" "${INSTALLER}" "${host}:/tmp/runner-apps.sh"
  ssh "${SSH_OPTS[@]}" "${host}" 'chmod +x /tmp/runner-apps.sh'
  if [[ -d "${SCRIPTS_DIR}" ]]; then
    ssh "${SSH_OPTS[@]}" "${host}" 'mkdir -p /tmp/scripts'
    scp -q "${SSH_OPTS[@]}" "${SCRIPTS_DIR}"/* "${host}:/tmp/scripts/"
  fi
  printf '%s\n' "✓ Files copied"
  printf '\n'

  # Run installer
  if ${DRY_RUN}; then
    printf '%s\n' "→ Running installer (dry run)..."
    ssh "${SSH_OPTS[@]}" "${host}" 'bash /tmp/runner-apps.sh --dry-run'
  else
    printf '%s\n' "→ Running installer..."
    ssh "${SSH_OPTS[@]}" "${host}" 'bash /tmp/runner-apps.sh'
  fi

  printf '\n'
  printf '%s\n' "✓ ${host} complete"
  printf '\n'
  SUCCEEDED=$((SUCCEEDED + 1))
done

# ─── Final summary ───────────────────────────────────────────────────────────
trap - ERR
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  Update complete"
printf '%s\n' "  Runners:   ${TOTAL} total, ${SUCCEEDED} succeeded, ${FAILED} failed"
if ${DRY_RUN}; then
  printf '%s\n' "  Mode:      DRY RUN (no changes made)"
fi
printf '%s\n' "════════════════════════════════════════════════════"
