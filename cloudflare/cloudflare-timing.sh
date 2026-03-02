#!/usr/bin/env bash
set -euo pipefail

# ─── Dry-run support ─────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Chrony setup failed at line ${LINENO}."' ERR

# ─── Load config ─────────────────────────────────────────────────────────────
if [[ -f /root/.secrets/gitlab.env ]]; then
  set -a
  # shellcheck source=/dev/null
  source /root/.secrets/gitlab.env
  set +a
fi

TZ_VALUE="${TIMEZONE:-UTC}"

# ─── Resolve config file ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHRONY_CONF="${REPO_ROOT}/config/chrony.conf"
if [[ ! -f "${CHRONY_CONF}" ]]; then
  CHRONY_CONF="/tmp/gitlab-chrony.conf"
fi

if [[ ! -f "${CHRONY_CONF}" ]]; then
  printf '%s\n' "✗ Missing chrony.conf"
  exit 1
fi

if ${DRY_RUN}; then
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  Timezone:  ${TZ_VALUE}"
  printf '\n'
  printf '%s\n' "  1. Set system timezone to ${TZ_VALUE}"
  printf '%s\n' "  2. Install chrony (if not present)"
  printf '%s\n' "  3. Back up /etc/chrony/chrony.conf → /etc/chrony/chrony.conf.bak"
  printf '%s\n' "  4. Write new config (Cloudflare NTS)"
  printf '%s\n' "  5. Restart chrony and verify NTS"
  printf '\n'
  printf '%s\n' "── Config to deploy: ──"
  cat "${CHRONY_CONF}"
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to apply."
  exit 0
fi

# ─── Step 1: Set timezone ────────────────────────────────────────────────────
printf '%s\n' "→ Setting timezone to ${TZ_VALUE}..."
if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "${TZ_VALUE}" 2>/dev/null; then
  printf '%s\n' "✓ Timezone set to ${TZ_VALUE} (timedatectl)"
else
  if [[ ! -f "/usr/share/zoneinfo/${TZ_VALUE}" ]]; then
    printf '%s\n' "✗ Invalid timezone: ${TZ_VALUE}"
    exit 1
  fi
  ln -sf "/usr/share/zoneinfo/${TZ_VALUE}" /etc/localtime
  printf '%s\n' "${TZ_VALUE}" > /etc/timezone
  printf '%s\n' "✓ Timezone set to ${TZ_VALUE} (zoneinfo fallback)"
fi

# ─── Step 2: Install chrony ──────────────────────────────────────────────────
printf '%s\n' "→ Installing chrony..."
apt-get update -qq
apt-get install -y -qq chrony > /dev/null
printf '%s\n' "✓ chrony installed"

# ─── Step 3: Back up existing config ─────────────────────────────────────────
if [[ -f /etc/chrony/chrony.conf ]] && [[ ! -f /etc/chrony/chrony.conf.bak ]]; then
  cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
  printf '%s\n' "✓ Backed up /etc/chrony/chrony.conf → chrony.conf.bak"
else
  printf '%s\n' "  Backup already exists or no existing config — skipping"
fi

# ─── Step 4: Deploy Cloudflare NTS config ────────────────────────────────────
printf '%s\n' "→ Writing /etc/chrony/chrony.conf..."
cp "${CHRONY_CONF}" /etc/chrony/chrony.conf
printf '%s\n' "✓ Config deployed"

# ──�� Step 5: Restart and verify ──────────────────────────────────────────────
printf '%s\n' "→ Restarting chrony..."
systemctl enable chrony 2>/dev/null || true
if systemctl restart chrony 2>/dev/null; then
  printf '%s\n' "✓ chrony restarted and enabled"
  printf '%s\n' "→ Waiting for NTS handshake..."
  sleep 3
  chronyc -n sources
  printf '\n'
  chronyc authdata
  printf '\n'
else
  # Unprivileged LXC containers cannot call adjtimex — chrony will fail.
  # Config is deployed; time sync is inherited from the Proxmox host.
  printf '%s\n' "⚠ chrony failed to start (likely unprivileged LXC — adjtimex not permitted)"
  printf '%s\n' "  Config deployed to /etc/chrony/chrony.conf — will work if container is made privileged"
  printf '%s\n' "  Time sync is inherited from the Proxmox host in the meantime"
fi

trap - ERR
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  Timezone: ${TZ_VALUE}"
printf '%s\n' "  Chrony config deployed (Cloudflare NTS + backup pool)"
printf '%s\n' "  Sources: time.cloudflare.com (NTS), pool.ntp.org"
printf '%s\n' "════════════════════════════════════════════════════"
