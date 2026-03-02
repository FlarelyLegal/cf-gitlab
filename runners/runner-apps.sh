#!/usr/bin/env bash
set -euo pipefail

# ─── Runner App Installer ────────────────────────────────────────────────────
# Installs all tools defined in runner-apps.json on the GitLab Runner LXC.
# Reads the JSON manifest and installs apt packages, Docker, Node.js, and
# global npm packages.
#
# Usage:
#   bash runner-apps.sh              # install everything
#   bash runner-apps.sh --dry-run    # show what would be installed
#
# Must be run as root on the GitLab LXC.
# Requires: jq, curl (installed as part of the apt section if missing).
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Runner app install failed at line ${LINENO}."' ERR

# ─── Resolve manifest ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/runner-apps.json"
if [[ ! -f "${MANIFEST}" ]]; then
  MANIFEST="/tmp/runner-apps.json"
fi
if [[ ! -f "${MANIFEST}" ]]; then
  printf '%s\n' "✗ Missing runner-apps.json"
  exit 1
fi

# ─── Bootstrap: ensure jq + curl exist ────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  if ${DRY_RUN}; then
    printf '%s\n' "  Would install jq + curl (bootstrap)"
  else
    printf '%s\n' "→ Bootstrap: installing jq + curl..."
    apt-get update -qq
    apt-get install -y -qq jq curl >/dev/null
    printf '%s\n' "✓ Bootstrap complete"
  fi
fi

# ─── Helper: check if an apt package is installed ────────────────────────────
is_apt_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# ─── Helper: check if an npm global package is installed ─────────────────────
is_npm_installed() {
  npm list -g --depth=0 "$1" >/dev/null 2>&1
}

# ─── 1. APT packages ─────────────────────────────────────────────────────────
printf '%s\n' "── APT Packages ──"
APT_TO_INSTALL=()

while IFS= read -r pkg; do
  if is_apt_installed "${pkg}"; then
    printf '%s\n' "  ✓ ${pkg} (installed)"
  else
    printf '%s\n' "  ○ ${pkg} (will install)"
    APT_TO_INSTALL+=("${pkg}")
  fi
done < <(jq -r '.apt.packages[].name' "${MANIFEST}")

if [[ ${#APT_TO_INSTALL[@]} -gt 0 ]]; then
  if ${DRY_RUN}; then
    printf '\n'
    printf '%s\n' "  Would run: apt-get install -y ${APT_TO_INSTALL[*]}"
  else
    printf '\n'
    printf '%s\n' "→ Installing ${#APT_TO_INSTALL[@]} apt packages..."
    apt-get update -qq
    apt-get install -y -qq "${APT_TO_INSTALL[@]}" >/dev/null
    printf '%s\n' "✓ APT packages installed"
  fi
else
  printf '%s\n' "  All apt packages already installed"
fi
printf '\n'

# ─── 2. Docker ────────────────────────────────────────────────────────────────
printf '%s\n' "── Docker ──"
DOCKER_TO_INSTALL=()

while IFS= read -r pkg; do
  if is_apt_installed "${pkg}"; then
    printf '%s\n' "  ✓ ${pkg} (installed)"
  else
    printf '%s\n' "  ○ ${pkg} (will install)"
    DOCKER_TO_INSTALL+=("${pkg}")
  fi
done < <(jq -r '.docker.packages[].name' "${MANIFEST}")

if [[ ${#DOCKER_TO_INSTALL[@]} -gt 0 ]]; then
  if ${DRY_RUN}; then
    printf '\n'
    printf '%s\n' "  Would add Docker apt repo + install: ${DOCKER_TO_INSTALL[*]}"
    printf '%s\n' "  Would run: usermod -aG docker gitlab-runner"
  else
    printf '\n'
    printf '%s\n' "→ Adding Docker apt repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    printf '%s\n' \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      $(. /etc/os-release && printf '%s' "${VERSION_CODENAME}") stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    printf '%s\n' "→ Installing Docker packages..."
    apt-get install -y -qq "${DOCKER_TO_INSTALL[@]}" >/dev/null
    printf '%s\n' "✓ Docker installed"
  fi
else
  printf '%s\n' "  All Docker packages already installed"
fi

# Ensure gitlab-runner is in docker group
if id gitlab-runner >/dev/null 2>&1; then
  if id -nG gitlab-runner | grep -qw docker; then
    printf '%s\n' "  ✓ gitlab-runner in docker group"
  else
    if ${DRY_RUN}; then
      printf '%s\n' "  Would run: usermod -aG docker gitlab-runner"
    else
      printf '%s\n' "→ Adding gitlab-runner to docker group..."
      usermod -aG docker gitlab-runner
      printf '%s\n' "✓ gitlab-runner added to docker group"
    fi
  fi
else
  printf '%s\n' "  ⚠ gitlab-runner user not found (install runner first)"
fi

# Weekly Docker prune cron (removes unused images, containers, volumes)
if command -v docker >/dev/null 2>&1; then
  if [[ -f /etc/cron.d/docker-prune ]]; then
    printf '%s\n' "  ✓ Docker prune cron already installed"
  else
    if ${DRY_RUN}; then
      printf '%s\n' "  Would install weekly Docker prune cron (Sunday 4am)"
    else
      cat >/etc/cron.d/docker-prune <<'CRON'
# Weekly Docker cleanup — prune images unused for 7+ days, plus dangling containers/networks
0 4 * * 0 root /usr/bin/docker image prune -af --filter "until=168h" >> /var/log/docker-prune.log 2>&1 && /usr/bin/docker container prune -f --filter "until=168h" >> /var/log/docker-prune.log 2>&1
CRON
      cat >/etc/logrotate.d/docker-prune <<'LOGROTATE'
/var/log/docker-prune.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
LOGROTATE
      printf '%s\n' "  ✓ Docker prune cron installed (Sunday 4am)"
    fi
  fi
fi
printf '\n'

# ─── 3. Node.js ──────────────────────────────────────────────────────────────
printf '%s\n' "── Node.js ──"
NODE_VERSION=$(jq -r '.node.version' "${MANIFEST}")

if command -v node >/dev/null 2>&1; then
  CURRENT_NODE=$(node --version | sed 's/v//' | cut -d. -f1)
  printf '%s\n' "  ✓ node v$(node --version | sed 's/v//') (installed)"
  if [[ "${CURRENT_NODE}" != "${NODE_VERSION}" ]]; then
    printf '%s\n' "  ⚠ Manifest wants Node ${NODE_VERSION}, currently ${CURRENT_NODE}"
  fi
else
  printf '%s\n' "  ○ node ${NODE_VERSION} (will install via NodeSource)"
  if ${DRY_RUN}; then
    printf '%s\n' "  Would add NodeSource repo for Node ${NODE_VERSION} + install nodejs"
  else
    printf '%s\n' "→ Adding NodeSource repository for Node ${NODE_VERSION}..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" -o /tmp/nodesource-setup.sh
    bash /tmp/nodesource-setup.sh
    rm -f /tmp/nodesource-setup.sh
    printf '%s\n' "→ Installing nodejs..."
    apt-get install -y -qq nodejs >/dev/null
    printf '%s\n' "✓ Node.js $(node --version) installed"
  fi
fi
printf '\n'

# ─── 4. Global npm packages ──────────────────────────────────────────────────
printf '%s\n' "── Global npm Packages ──"
NPM_TO_INSTALL=()

while IFS= read -r pkg; do
  if is_npm_installed "${pkg}"; then
    INSTALLED_VER=$(npm list -g --depth=0 "${pkg}" 2>/dev/null | grep "${pkg}@" | sed "s/.*${pkg}@//" | tr -d '[:space:]')
    printf '%s\n' "  ✓ ${pkg}@${INSTALLED_VER}"
  else
    printf '%s\n' "  ○ ${pkg} (will install)"
    NPM_TO_INSTALL+=("${pkg}")
  fi
done < <(jq -r '.npm_global.packages[].name' "${MANIFEST}")

if [[ ${#NPM_TO_INSTALL[@]} -gt 0 ]]; then
  if ${DRY_RUN}; then
    printf '\n'
    printf '%s\n' "  Would run: npm install -g ${NPM_TO_INSTALL[*]}"
  else
    printf '\n'
    printf '%s\n' "→ Installing ${#NPM_TO_INSTALL[@]} npm packages globally..."
    npm install -g "${NPM_TO_INSTALL[@]}" >/dev/null
    printf '%s\n' "✓ npm global packages installed"
  fi
else
  printf '%s\n' "  All npm global packages already installed"
fi
printf '\n'

# ─── Summary ──────────────────────────────────────────────────────────────────
trap - ERR

if ${DRY_RUN}; then
  printf '%s\n' "✓ Dry run complete. Run without --dry-run to install."
else
  printf '%s\n' "════════════════════════════════════════════════════"
  printf '%s\n' "  Runner apps installed"
  printf '\n'
  printf '%s\n' "  APT:    $(jq '.apt.packages | length' "${MANIFEST}") packages"
  printf '%s\n' "  Docker: $(docker --version 2>/dev/null | cut -d, -f1 || printf 'not found')"
  printf '%s\n' "  Node:   $(node --version 2>/dev/null || printf 'not found')"
  printf '%s\n' "  npm:    $(npm --version 2>/dev/null || printf 'not found')"
  printf '%s\n' "  Global: $(jq '.npm_global.packages | length' "${MANIFEST}") npm packages"
  printf '%s\n' "════════════════════════════════════════════════════"
fi
