#!/usr/bin/env bash
set -euo pipefail

# ─── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ MOTD setup failed at line ${LINENO}."' ERR

# ─── Load config ──────────────────────────────────────────────────────────────
if [[ ! -f /root/.secrets/gitlab.env ]]; then
  printf '%s\n' "✗ Missing /root/.secrets/gitlab.env — run deploy.sh first."
  exit 1
fi
set -a
# shellcheck source=/dev/null
source /root/.secrets/gitlab.env
set +a

# ─── Resolve banner ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/banner.txt" ]]; then
  ASCII_BANNER="$(cat "${SCRIPT_DIR}/banner.txt")"
elif [[ -f /tmp/gitlab-banner.txt ]]; then
  ASCII_BANNER="$(cat /tmp/gitlab-banner.txt)"
else
  printf '%s\n' "⚠ No banner.txt found — using plain text fallback"
  ASCII_BANNER="GITLAB"
fi

# ─── System info ──────────────────────────────────────────────────────────────
LXC_IP="$(hostname -I | awk '{print $1}')"
LXC_HOSTNAME="$(hostname)"
# shellcheck source=/dev/null
LXC_OS="$(. /etc/os-release && printf '%s\n' "$PRETTY_NAME")"

# ─── Build MOTD content ──────────────────────────────────────────────────
MOTD_CONTENT="
${ASCII_BANNER}

  GitLab Self-Hosted Instance
  URL:           https://${GITLAB_DOMAIN}
  Organization:  ${ORG_NAME} — ${ORG_URL}
  Hostname:      ${LXC_HOSTNAME}
  IP Address:    ${LXC_IP}
  OS:            ${LXC_OS}
"

if ${DRY_RUN}; then
  printf '%s\n' "── Dry run — MOTD preview: ──"
  printf '%s\n' "${MOTD_CONTENT}"
  printf '%s\n' "✓ Dry run complete. Run without --dry-run to write /etc/motd."
  exit 0
fi

# ─── Write MOTD ──────────────────────────────────────────────────────────
printf '%s\n' "→ Writing /etc/motd..."
printf '%s\n' "${MOTD_CONTENT}" > /etc/motd
printf '%s\n' "✓ MOTD set"
