#!/usr/bin/env bash
# =============================================================================
# gitlab-runner-container.sh
#
# One-shot provisioner: creates a Debian 13 LXC on Proxmox and turns it into
# a fully-functional GitLab CI runner with Docker, Dockge, Node.js, Terraform,
# OpenTofu, and all the linting/CI tooling you'd expect on a native host.
#
# Everything is pinned (template hash, GPG keys, package versions, image
# digests) so the build is reproducible and supply-chain safe.
#
# Usage:
#   ./gitlab-runner-container.sh                       # uses ./gitlab-runner-container.env
#   ./gitlab-runner-container.sh my-runner.env         # uses custom env file
#   ./gitlab-runner-container.sh --dry-run             # validate config and print plan
#   ./gitlab-runner-container.sh --dry-run my.env      # dry-run with custom env file
# =============================================================================
set -euo pipefail

# -- colours -------------------------------------------------------------------
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'
ok() { printf '%b[OK]%b   %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%b[INFO]%b %s\n' "$CYN" "$RST" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YEL" "$RST" "$*"; }
die() {
  printf '%b[FAIL]%b %s\n' "$RED" "$RST" "$*" >&2
  exit 1
}

# -- parse arguments -----------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"
ENV_FILE=""
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) die "Unknown option: $_arg" ;;
    *) ENV_FILE="$_arg" ;;
  esac
done
ENV_FILE="${ENV_FILE:-$(dirname "$0")/gitlab-runner-container.env}"

# -- load .env -----------------------------------------------------------------
[[ -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"

# shellcheck disable=SC1090
source "$ENV_FILE"
ok "Loaded config from $ENV_FILE"

# -- load SSH keys from file ---------------------------------------------------
_SSH_KEYS_FILE="${SSH_KEYS_FILE:-$(dirname "$0")/sshkeys.txt}"
if [[ -f "$_SSH_KEYS_FILE" ]]; then
  # Strip comments and blank lines
  SSH_KEYS=$(grep -v '^\s*#' "$_SSH_KEYS_FILE" | grep -v '^\s*$' || true)
  _KEY_COUNT=$(printf '%s' "$SSH_KEYS" | grep -c '^ssh-' || true)
  ok "Loaded $_KEY_COUNT SSH key(s) from $_SSH_KEYS_FILE"
else
  SSH_KEYS=""
  info "No SSH keys file found at $_SSH_KEYS_FILE -- skipping key injection"
fi

# -- required vars -------------------------------------------------------------
for var in CTID HOSTNAME PASSWORD CORES MEMORY DISK_SIZE IP GATEWAY \
  NAMESERVER SEARCHDOMAIN TEMPLATE TEMPLATE_STORAGE CONTAINER_STORAGE; do
  [[ -n "${!var:-}" ]] || die "Required variable $var is not set"
done

# -- pre-flight ----------------------------------------------------------------
if [[ "$DRY_RUN" == "1" ]]; then
  if command -v pct >/dev/null 2>&1; then
    ok "pct found (Proxmox host)"
    if pct status "$CTID" &>/dev/null; then
      warn "Container $CTID already exists (would fail on real run)"
    fi
  else
    info "pct not found -- skipping host checks (dry-run only)"
  fi
else
  command -v pct >/dev/null 2>&1 || die "pct not found -- run this on a Proxmox host"
  command -v curl >/dev/null 2>&1 || die "curl not found on host"
  if pct status "$CTID" &>/dev/null; then
    die "Container $CTID already exists. Destroy it first or pick a different CTID."
  fi
fi

# -- verify template hash ------------------------------------------------------
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"
if [[ "$DRY_RUN" == "1" ]]; then
  if [[ -f "$TEMPLATE_PATH" && -n "${TEMPLATE_SHA256:-}" ]]; then
    info "Verifying template integrity..."
    ACTUAL=$(sha256sum "$TEMPLATE_PATH" | awk '{print $1}')
    [[ "$ACTUAL" == "$TEMPLATE_SHA256" ]] \
      || die "Template hash mismatch!\n  Expected: $TEMPLATE_SHA256\n  Got:      $ACTUAL"
    ok "Template hash verified: ${TEMPLATE_SHA256:0:16}..."
  elif [[ -n "${TEMPLATE_SHA256:-}" ]]; then
    info "Template not found locally -- hash will be verified at provision time"
  else
    warn "TEMPLATE_SHA256 not set -- template will not be verified"
  fi
else
  if [[ ! -f "$TEMPLATE_PATH" ]]; then
    info "Template not found locally, downloading..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi
  if [[ -n "${TEMPLATE_SHA256:-}" ]]; then
    info "Verifying template integrity..."
    ACTUAL=$(sha256sum "$TEMPLATE_PATH" | awk '{print $1}')
    [[ "$ACTUAL" == "$TEMPLATE_SHA256" ]] \
      || die "Template hash mismatch!\n  Expected: $TEMPLATE_SHA256\n  Got:      $ACTUAL"
    ok "Template hash verified: ${TEMPLATE_SHA256:0:16}..."
  else
    warn "TEMPLATE_SHA256 not set -- skipping template verification"
  fi
fi

# -- build pct create command --------------------------------------------------
PCT_CMD=(
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
  -hostname "$HOSTNAME"
  -password "$PASSWORD"
  -cores "$CORES"
  -memory "$MEMORY"
  -rootfs "${CONTAINER_STORAGE}:${DISK_SIZE}"
  -"${NET_ID:-net0}" "name=${NET_NAME:-eth0},bridge=${BRIDGE:-vmbr1},ip=${IP},gw=${GATEWAY},tag=${VLAN:-},mtu=${MTU:-1500}"
  -nameserver "$NAMESERVER"
  -searchdomain "$SEARCHDOMAIN"
  -timezone "${TIMEZONE:-UTC}"
  -onboot "${ONBOOT:-0}"
  -unprivileged "${UNPRIVILEGED:-1}"
)
[[ -n "${FEATURES:-}" ]] && PCT_CMD+=(-features "$FEATURES")
[[ -n "${SWAP:-}" ]] && PCT_CMD+=(-swap "$SWAP")
[[ -n "${PCT_TAGS:-}" ]] && PCT_CMD+=(-tags "$PCT_TAGS")

# -- validate optional feature dependencies ------------------------------------
if [[ "${INSTALL_DOCKER:-no}" == "yes" ]]; then
  for var in DOCKER_CE_VERSION DOCKER_CE_CLI_VERSION CONTAINERD_VERSION \
    DOCKER_BUILDX_VERSION DOCKER_COMPOSE_VERSION; do
    [[ -n "${!var:-}" ]] || die "INSTALL_DOCKER=yes but $var is not set"
  done
  ok "Docker pins validated"
fi
if [[ "${INSTALL_DOCKGE:-no}" == "yes" ]]; then
  [[ -n "${DOCKGE_IMAGE_DIGEST:-}" ]] || die "INSTALL_DOCKGE=yes but DOCKGE_IMAGE_DIGEST is not set"
  ok "Dockge digest validated"
fi
if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then
  [[ -n "${GITLAB_RUNNER_VERSION:-}" ]] || die "INSTALL_GITLAB_RUNNER=yes but GITLAB_RUNNER_VERSION is not set"
  ok "GitLab Runner version validated"
fi

# -- dry-run: print execution plan and exit ------------------------------------
if [[ "$DRY_RUN" == "1" ]]; then
  printf '\n'
  printf '============================================================\n'
  info "DRY RUN -- no changes will be made"
  printf '============================================================\n'

  printf '\n'
  info "pct create command:"
  printf '  %s\n' "${PCT_CMD[*]}"

  printf '\n--- LXC Container ---\n'
  info "CTID:        $CTID"
  info "Hostname:    $HOSTNAME"
  info "Resources:   ${CORES} cores, ${MEMORY}MB RAM, ${DISK_SIZE} disk"
  info "Network:     ${IP} gw ${GATEWAY} bridge ${BRIDGE:-vmbr1}"
  info "  Net device:  -${NET_ID:-net0} name=${NET_NAME:-eth0}"
  info "DNS:         ${NAMESERVER} (${SEARCHDOMAIN})"
  info "Template:    ${TEMPLATE}"
  [[ -n "${TEMPLATE_SHA256:-}" ]] \
    && info "  sha256:    ${TEMPLATE_SHA256:0:16}... (verified)"
  info "Features:    ${FEATURES:-none}"
  info "Proxmox tags: ${PCT_TAGS:-none}"

  KEY_COUNT=0
  [[ -n "${SSH_KEYS:-}" ]] && KEY_COUNT=$(printf '%s' "$SSH_KEYS" | grep -c '^ssh-' || true)
  if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then
    info "SSH keys:    ${KEY_COUNT} key(s) for root + gitlab-runner"
  else
    info "SSH keys:    ${KEY_COUNT} key(s) for root"
  fi
  info "Fix locale:  ${FIX_LOCALE:-no}"

  if [[ "${INSTALL_DOCKER:-no}" == "yes" ]]; then
    printf '\n--- Docker ---\n'
    info "docker-ce:          ${DOCKER_CE_VERSION}"
    info "docker-ce-cli:      ${DOCKER_CE_CLI_VERSION}"
    info "containerd.io:      ${CONTAINERD_VERSION}"
    info "docker-buildx:      ${DOCKER_BUILDX_VERSION}"
    info "docker-compose:     ${DOCKER_COMPOSE_VERSION}"
    info "Daemon MTU:         ${DOCKER_MTU:-1500}"
    [[ -n "${DOCKER_GPG_SHA256:-}" ]] \
      && info "GPG key sha256:     ${DOCKER_GPG_SHA256:0:16}..."
    info "Packages held:      yes"
  fi

  if [[ "${INSTALL_DOCKGE:-no}" == "yes" ]]; then
    printf '\n--- Dockge ---\n'
    info "Image digest:       ${DOCKGE_IMAGE_DIGEST}"
    info "Port:               ${DOCKGE_PORT:-5001}"
  fi

  _DRY_STACKS_DIR="${STACKS_DIR:-$(dirname "$0")/stacks}"
  if [[ -d "$_DRY_STACKS_DIR" ]]; then
    printf '\n--- Stacks ---\n'
    info "Stacks dir:         ${_DRY_STACKS_DIR}"
    for _sd in "$_DRY_STACKS_DIR"/*/; do
      [[ -f "${_sd}compose.yaml" ]] && info "  $(basename "$_sd")"
    done
  fi

  if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then
    printf '\n--- GitLab Runner ---\n'
    info "gitlab-runner:      ${GITLAB_RUNNER_VERSION}"
    info "Runner type:        ${GITLAB_RUNNER_TYPE:-instance_type}"
    info "Executor:           ${GITLAB_RUNNER_EXECUTOR:-shell}"
    info "Tags:               ${GITLAB_RUNNER_TAGS:-none}"
    info "Run untagged:       ${GITLAB_RUNNER_RUN_UNTAGGED:-false}"
    info "Concurrent:         ${GITLAB_RUNNER_CONCURRENT:-2}"
    info "Limit:              ${GITLAB_RUNNER_LIMIT:-1}"
    info "Output limit:       ${GITLAB_RUNNER_OUTPUT_LIMIT:-8192}"
    info "CPU quota:          ${RUNNER_CPU_QUOTA:-600%}"
    info "Memory max:         ${RUNNER_MEMORY_MAX:-6G}"
    [[ -n "${GITLAB_URL:-}" ]] \
      && info "GitLab URL:         ${GITLAB_URL}"
    [[ -n "${GITLAB_PAT:-}" ]] \
      && info "GitLab PAT:         ${GITLAB_PAT:0:10}... (set)"
    [[ -n "${GITLAB_RUNNER_GPG_SHA256:-}" ]] \
      && info "GPG key sha256:     ${GITLAB_RUNNER_GPG_SHA256:0:16}..."
  fi

  if [[ "${INSTALL_NODEJS:-no}" == "yes" ]]; then
    printf '\n--- Node.js ---\n'
    info "nodejs:             ${NODEJS_VERSION:-not set}"
    [[ -n "${NPM_GLOBALS:-}" ]] \
      && info "NPM globals:        ${NPM_GLOBALS}"
    [[ -n "${NODESOURCE_GPG_SHA256:-}" ]] \
      && info "GPG key sha256:     ${NODESOURCE_GPG_SHA256:0:16}..."
  fi

  if [[ "${INSTALL_TERRAFORM:-no}" == "yes" ]]; then
    printf '\n--- Terraform ---\n'
    info "terraform:          ${TERRAFORM_VERSION:-not set}"
    [[ -n "${HASHICORP_GPG_SHA256:-}" ]] \
      && info "GPG key sha256:     ${HASHICORP_GPG_SHA256:0:16}..."
  fi

  if [[ "${INSTALL_OPENTOFU:-no}" == "yes" ]]; then
    printf '\n--- OpenTofu ---\n'
    info "tofu:               ${TOFU_VERSION:-not set}"
    [[ -n "${OPENTOFU_GPG_SHA256:-}" ]] \
      && info "GPG key sha256:     ${OPENTOFU_GPG_SHA256:0:16}..."
  fi

  if [[ "${INSTALL_BUILD_TOOLS:-no}" == "yes" ]]; then
    printf '\n--- Build Tools ---\n'
    info "build-essential, python3-dev, python3-pip, python3-venv"
    [[ -n "${PIP_PACKAGES:-}" ]] \
      && info "Pip packages:       ${PIP_PACKAGES}"
  fi

  if [[ -n "${SYSCTL_INOTIFY_MAX_USER_WATCHES:-}" ]]; then
    printf '\n--- Sysctl Tuning ---\n'
    info "max_user_instances: ${SYSCTL_INOTIFY_MAX_USER_INSTANCES:-65536}"
    info "max_user_watches:   ${SYSCTL_INOTIFY_MAX_USER_WATCHES}"
    info "max_queued_events:  ${SYSCTL_INOTIFY_MAX_QUEUED_EVENTS:-8388608}"
  fi

  printf '\n--- Health Check ---\n'
  info "Port:               ${HEALTH_PORT:-5000}"
  info "Endpoint:           /health"
  info "Activation:         systemd socket (zero idle cost)"

  if [[ "${INSTALL_UFW:-no}" == "yes" ]]; then
    printf '\n--- UFW Firewall ---\n'
    info "Default inbound:    deny"
    info "Default outbound:   allow"
    info "Default routed:     allow (Docker)"
    info "Allow from:         ${UFW_ALLOW_FROM:-10.0.0.0/8}"
    info "Inbound ports:      ${UFW_INBOUND_PORTS:-22}"
    info "Docker forward:     ${NET_NAME:-eth0} -> docker0"
  fi

  printf '\n============================================================\n'
  ok "Validation passed -- config is ready to provision"
  printf '============================================================\n'
  printf '\n'
  exit 0
fi

# -- create + start container --------------------------------------------------
info "pct create command:"
printf '  %s\n\n' "${PCT_CMD[*]}"
info "Creating container $CTID..."
"${PCT_CMD[@]}"
ok "Container $CTID created"

info "Starting container $CTID..."
pct start "$CTID"

info "Waiting for container to boot..."
for _i in $(seq 1 30); do
  pct exec "$CTID" -- true &>/dev/null && break
  sleep 1
done
pct exec "$CTID" -- true || die "Container failed to start within 30s"
ok "Container $CTID is running"

# ==============================================================================
# Helper: push a script into the container and run it
# ==============================================================================
run_in_ct() {
  local script_content="$1"
  local description="${2:-inline script}"
  local _tmp
  _tmp=$(mktemp)
  echo "$script_content" >"$_tmp"
  pct push "$CTID" "$_tmp" /tmp/_provision_step.sh
  rm -f "$_tmp"
  info "Running: $description"
  pct exec "$CTID" -- bash /tmp/_provision_step.sh
  pct exec "$CTID" -- rm -f /tmp/_provision_step.sh
}

# ==============================================================================
# PHASE 1: Base system (SSH keys, locale)
# ==============================================================================

# -- inject SSH keys (root) ----------------------------------------------------
if [[ -n "${SSH_KEYS:-}" ]]; then
  info "Injecting SSH keys (root)..."
  _TMPKEYS=$(mktemp)
  echo "$SSH_KEYS" >"$_TMPKEYS"
  pct push "$CTID" "$_TMPKEYS" /tmp/authorized_keys_inject
  rm -f "$_TMPKEYS"
  pct exec "$CTID" -- bash -c '
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    mv /tmp/authorized_keys_inject /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  '
  KEY_COUNT=$(echo "$SSH_KEYS" | grep -c '^ssh-' || true)
  ok "Injected $KEY_COUNT SSH key(s) for root"
fi

# -- fix locale ----------------------------------------------------------------
if [[ "${FIX_LOCALE:-no}" == "yes" ]]; then
  run_in_ct '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq locales >/dev/null 2>&1
    sed -i "s/^# *en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    locale-gen >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  ' "Fix locale (en_US.UTF-8)"
  ok "Locale fixed"
fi

# -- MOTD banner + login info --------------------------------------------------
info "Configuring MOTD banner..."

_MOTD_SUBTITLE="GitLab Runner — ${GITLAB_URL:-https://gitlab.example.com}"

# Banner file: look for banner-runner.txt next to this script
_TMP_MOTD=$(mktemp)
_BANNER_FILE="$(dirname "$0")/banner-runner.txt"
if [[ -f "$_BANNER_FILE" ]]; then
  cp "$_BANNER_FILE" "$_TMP_MOTD"
else
  warn "banner-runner.txt not found next to script -- using plain text fallback"
  printf '\n  ── GitLab Runner ──\n\n' >"$_TMP_MOTD"
fi
printf '  %s\n\n' "$_MOTD_SUBTITLE" >>"$_TMP_MOTD"
pct push "$CTID" "$_TMP_MOTD" /etc/motd
rm -f "$_TMP_MOTD"

# Dynamic login info (runs on every SSH/console login)
_TMP_PROFILE=$(mktemp)
cat >"$_TMP_PROFILE" <<'PROFILEEOF'
printf '\n'
printf '    OS:       %s\n' "$(grep ^PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
printf '    Hostname: %s\n' "$(hostname)"
printf '    IP:       %s\n' "$(hostname -I | awk '{print $1}')"
if command -v gitlab-runner >/dev/null 2>&1; then
    _ver=$(gitlab-runner --version 2>/dev/null | head -1 | awk '{print $2}')
    _status=$(systemctl is-active gitlab-runner 2>/dev/null || printf 'unknown')
    printf '    Runner:   %s (%s)\n' "$_ver" "$_status"
fi
if command -v docker >/dev/null 2>&1; then
    _dver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    printf '    Docker:   %s\n' "$_dver"
fi
_ip=$(hostname -I | awk '{print $1}')
printf '    Health:   http://%s:%s/health\n' "$_ip" "__HEALTH_PORT__"
printf '\n'
PROFILEEOF
sed -i "s/__HEALTH_PORT__/${HEALTH_PORT:-5000}/" "$_TMP_PROFILE"

pct push "$CTID" "$_TMP_PROFILE" /etc/profile.d/00_lxc-details.sh
pct exec "$CTID" -- chmod 644 /etc/profile.d/00_lxc-details.sh
rm -f "$_TMP_PROFILE"
ok "MOTD banner and login info configured"

# ==============================================================================
# PHASE 2: Docker + Dockge
# ==============================================================================

# -- install Docker (pinned) --------------------------------------------------
if [[ "${INSTALL_DOCKER:-no}" == "yes" ]]; then
  # (version pins already validated in pre-flight)
  info "Installing Docker packages:"
  printf '         docker-ce=%s\n' "${DOCKER_CE_VERSION}"
  printf '         docker-ce-cli=%s\n' "${DOCKER_CE_CLI_VERSION}"
  printf '         containerd.io=%s\n' "${CONTAINERD_VERSION}"
  printf '         docker-buildx-plugin=%s\n' "${DOCKER_BUILDX_VERSION}"
  printf '         docker-compose-plugin=%s\n' "${DOCKER_COMPOSE_VERSION}"

  run_in_ct "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null 2>&1

    # Docker GPG key -- download and verify hash
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    ACTUAL=\$(sha256sum /etc/apt/keyrings/docker.asc | awk '{print \$1}')
    EXPECTED='${DOCKER_GPG_SHA256}'
    if [[ -n \"\$EXPECTED\" && \"\$ACTUAL\" != \"\$EXPECTED\" ]]; then
      echo 'FATAL: Docker GPG key hash mismatch!'
      rm -f /etc/apt/keyrings/docker.asc
      exit 1
    fi
    echo 'Docker GPG key hash verified'

    ARCH=\$(dpkg --print-architecture)
    CODENAME=\$(. /etc/os-release && echo \"\$VERSION_CODENAME\")
    echo \"deb [arch=\$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$CODENAME stable\" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq

    apt-get install -y \
      docker-ce='${DOCKER_CE_VERSION}' \
      docker-ce-cli='${DOCKER_CE_CLI_VERSION}' \
      containerd.io='${CONTAINERD_VERSION}' \
      docker-buildx-plugin='${DOCKER_BUILDX_VERSION}' \
      docker-compose-plugin='${DOCKER_COMPOSE_VERSION}'

    for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
      echo \"\$pkg hold\" | dpkg --set-selections
    done

    # Configure Docker daemon (MTU, etc.)
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<DAEMONEOF
{
  \"mtu\": ${DOCKER_MTU:-1500}
}
DAEMONEOF

    systemctl enable --now docker >/dev/null 2>&1
    echo 'Docker install complete'
  " "Install Docker (pinned)"

  DOCKER_VER=$(pct exec "$CTID" -- docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  COMPOSE_VER=$(pct exec "$CTID" -- docker compose version 2>/dev/null | awk '{print $NF}')
  ok "Docker $DOCKER_VER, Compose $COMPOSE_VER (packages held)"
fi

# -- install Dockge (pinned) --------------------------------------------------
if [[ "${INSTALL_DOCKGE:-no}" == "yes" ]]; then
  # (digest already validated in pre-flight)
  DOCKGE_PORT="${DOCKGE_PORT:-5001}"

  _TMPDOCKGE=$(mktemp)
  cat >"$_TMPDOCKGE" <<DOCKGEOF
services:
  dockge:
    image: louislam/dockge@${DOCKGE_IMAGE_DIGEST}
    restart: unless-stopped
    ports:
      - ${DOCKGE_PORT}:5001
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 256m
          pids: 128
        reservations:
          memory: 64m
DOCKGEOF

  pct exec "$CTID" -- mkdir -p /opt/dockge /opt/stacks /opt/stacks/data
  pct push "$CTID" "$_TMPDOCKGE" /opt/dockge/compose.yaml
  rm -f "$_TMPDOCKGE"

  info "Pulling Dockge image (pinned digest)..."
  pct exec "$CTID" -- docker compose -f /opt/dockge/compose.yaml pull
  info "Starting Dockge..."
  pct exec "$CTID" -- docker compose -f /opt/dockge/compose.yaml up -d
  ok "Dockge running on port $DOCKGE_PORT"
fi

# ==============================================================================
# PHASE 2b: Deploy additional stacks
# ==============================================================================

# Drop compose dirs in STACKS_DIR and they'll be pushed into /opt/stacks/.
# Expected layout:  STACKS_DIR/<stack-name>/compose.yaml
_STACKS_DIR="${STACKS_DIR:-$(dirname "$0")/stacks}"
if [[ -d "$_STACKS_DIR" ]]; then
  info "Deploying stacks from $_STACKS_DIR..."
  for stack_dir in "$_STACKS_DIR"/*/; do
    stack_name=$(basename "$stack_dir")
    if [[ -f "${stack_dir}compose.yaml" ]]; then
      info "  Deploying stack: $stack_name"
      pct exec "$CTID" -- mkdir -p "/opt/stacks/${stack_name}" "/opt/stacks/data/${stack_name}"
      pct push "$CTID" "${stack_dir}compose.yaml" "/opt/stacks/${stack_name}/compose.yaml"

      # Push .env if it exists
      if [[ -f "${stack_dir}.env" ]]; then
        pct push "$CTID" "${stack_dir}.env" "/opt/stacks/${stack_name}/.env"
      fi

      pct exec "$CTID" -- docker compose -f "/opt/stacks/${stack_name}/compose.yaml" pull
      pct exec "$CTID" -- docker compose -f "/opt/stacks/${stack_name}/compose.yaml" up -d
      ok "  Stack $stack_name started"
    else
      warn "  Skipping $stack_name -- no compose.yaml found"
    fi
  done
fi

# ==============================================================================
# PHASE 3: APT repos + packages for GitLab Runner toolchain
# ==============================================================================

if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then

  # -- Add GitLab Runner APT repo ----------------------------------------------
  run_in_ct "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq curl gnupg apt-transport-https >/dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings

    # ── GitLab Runner repo ──
    curl -fsSL https://packages.gitlab.com/runner/gitlab-runner/gpgkey \
      | gpg --dearmor -o /etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg
    chmod a+r /etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg

    ACTUAL=\$(sha256sum /etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg | awk '{print \$1}')
    EXPECTED='${GITLAB_RUNNER_GPG_SHA256}'
    if [[ -n \"\$EXPECTED\" && \"\$ACTUAL\" != \"\$EXPECTED\" ]]; then
      echo 'FATAL: GitLab Runner GPG key hash mismatch!'
      echo \"  Expected: \$EXPECTED\"
      echo \"  Got:      \$ACTUAL\"
      exit 1
    fi
    echo 'GitLab Runner GPG key verified'

    CODENAME=\$(. /etc/os-release && echo \"\$VERSION_CODENAME\")
    cat > /etc/apt/sources.list.d/runner_gitlab-runner.list <<REPOEOF
deb [signed-by=/etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg] https://packages.gitlab.com/runner/gitlab-runner/debian/ \$CODENAME main
deb-src [signed-by=/etc/apt/keyrings/runner_gitlab-runner-archive-keyring.gpg] https://packages.gitlab.com/runner/gitlab-runner/debian/ \$CODENAME main
REPOEOF

    echo 'GitLab Runner APT repo added'
  " "Add GitLab Runner APT repo"
  ok "GitLab Runner repo added"

  # -- Add NodeSource repo (if requested) --------------------------------------
  if [[ "${INSTALL_NODEJS:-no}" == "yes" ]]; then
    run_in_ct "
      set -euo pipefail
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
      chmod a+r /usr/share/keyrings/nodesource.gpg

      ACTUAL=\$(sha256sum /usr/share/keyrings/nodesource.gpg | awk '{print \$1}')
      EXPECTED='${NODESOURCE_GPG_SHA256}'
      if [[ -n \"\$EXPECTED\" && \"\$ACTUAL\" != \"\$EXPECTED\" ]]; then
        echo 'FATAL: NodeSource GPG key hash mismatch!'
        echo \"  Expected: \$EXPECTED\"
        echo \"  Got:      \$ACTUAL\"
        exit 1
      fi
      echo 'NodeSource GPG key verified'

      cat > /etc/apt/sources.list.d/nodesource.sources <<REPOEOF
Types: deb
URIs: https://deb.nodesource.com/node_22.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
REPOEOF

      echo 'NodeSource repo added'
    " "Add NodeSource 22.x APT repo"
    ok "NodeSource repo added"
  fi

  # -- Add HashiCorp repo (if requested) ---------------------------------------
  if [[ "${INSTALL_TERRAFORM:-no}" == "yes" ]]; then
    run_in_ct "
      set -euo pipefail
      curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      chmod a+r /usr/share/keyrings/hashicorp-archive-keyring.gpg

      ACTUAL=\$(sha256sum /usr/share/keyrings/hashicorp-archive-keyring.gpg | awk '{print \$1}')
      EXPECTED='${HASHICORP_GPG_SHA256}'
      if [[ -n \"\$EXPECTED\" && \"\$ACTUAL\" != \"\$EXPECTED\" ]]; then
        echo 'FATAL: HashiCorp GPG key hash mismatch!'
        echo \"  Expected: \$EXPECTED\"
        echo \"  Got:      \$ACTUAL\"
        exit 1
      fi
      echo 'HashiCorp GPG key verified'

      CODENAME=\$(. /etc/os-release && echo \"\$VERSION_CODENAME\")
      echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$CODENAME main\" \
        > /etc/apt/sources.list.d/hashicorp.list

      echo 'HashiCorp repo added'
    " "Add HashiCorp APT repo"
    ok "HashiCorp repo added"
  fi

  # -- Add OpenTofu repo (if requested) ----------------------------------------
  if [[ "${INSTALL_OPENTOFU:-no}" == "yes" ]]; then
    run_in_ct "
      set -euo pipefail
      install -m 0755 -d /etc/apt/keyrings

      curl -fsSL https://get.opentofu.org/opentofu.gpg \
        -o /etc/apt/keyrings/opentofu.gpg
      chmod a+r /etc/apt/keyrings/opentofu.gpg

      ACTUAL=\$(sha256sum /etc/apt/keyrings/opentofu.gpg | awk '{print \$1}')
      EXPECTED='${OPENTOFU_GPG_SHA256}'
      if [[ -n \"\$EXPECTED\" && \"\$ACTUAL\" != \"\$EXPECTED\" ]]; then
        echo 'FATAL: OpenTofu GPG key hash mismatch!'
        echo \"  Expected: \$EXPECTED\"
        echo \"  Got:      \$ACTUAL\"
        exit 1
      fi

      curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey \
        | gpg --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg
      chmod a+r /etc/apt/keyrings/opentofu-repo.gpg

      ACTUAL2=\$(sha256sum /etc/apt/keyrings/opentofu-repo.gpg | awk '{print \$1}')
      EXPECTED2='${OPENTOFU_REPO_GPG_SHA256}'
      if [[ -n \"\$EXPECTED2\" && \"\$ACTUAL2\" != \"\$EXPECTED2\" ]]; then
        echo 'FATAL: OpenTofu repo GPG key hash mismatch!'
        echo \"  Expected: \$EXPECTED2\"
        echo \"  Got:      \$ACTUAL2\"
        exit 1
      fi
      echo 'OpenTofu GPG keys verified'

      cat > /etc/apt/sources.list.d/opentofu.list <<REPOEOF
deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main
deb-src [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main
REPOEOF

      echo 'OpenTofu repo added'
    " "Add OpenTofu APT repo"
    ok "OpenTofu repo added"
  fi

  # -- Install all APT packages ------------------------------------------------

  # Build the package list dynamically
  _PKGS="gitlab-runner=${GITLAB_RUNNER_VERSION}"
  _PKGS="$_PKGS git jq rsync openssh-client"
  [[ "${INSTALL_NODEJS:-no}" == "yes" ]] && _PKGS="$_PKGS nodejs=${NODEJS_VERSION}"
  [[ "${INSTALL_TERRAFORM:-no}" == "yes" ]] && _PKGS="$_PKGS terraform=${TERRAFORM_VERSION}"
  [[ "${INSTALL_OPENTOFU:-no}" == "yes" ]] && _PKGS="$_PKGS tofu=${TOFU_VERSION}"
  [[ "${INSTALL_BUILD_TOOLS:-no}" == "yes" ]] && _PKGS="$_PKGS build-essential python3-dev python3-pip python3-venv"

  info "Installing APT packages:"
  for _p in $_PKGS; do
    printf '         %s\n' "$_p"
  done

  run_in_ct "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y ${_PKGS}

    # Hold pinned packages
    for pkg in gitlab-runner ${INSTALL_NODEJS:+nodejs} ${INSTALL_TERRAFORM:+terraform} ${INSTALL_OPENTOFU:+tofu}; do
      [[ -n \"\$pkg\" ]] && echo \"\$pkg hold\" | dpkg --set-selections 2>/dev/null || true
    done

    echo 'APT packages installed and held'
  " "Install APT packages"

  ok "Packages installed: gitlab-runner $(pct exec "$CTID" -- gitlab-runner --version 2>/dev/null | head -1 | awk '{print $2}')"
  [[ "${INSTALL_NODEJS:-no}" == "yes" ]] && ok "Node.js $(pct exec "$CTID" -- node --version 2>/dev/null)"
  [[ "${INSTALL_TERRAFORM:-no}" == "yes" ]] && ok "Terraform $(pct exec "$CTID" -- terraform --version 2>/dev/null | head -1 | awk '{print $2}')"
  [[ "${INSTALL_OPENTOFU:-no}" == "yes" ]] && ok "OpenTofu $(pct exec "$CTID" -- tofu --version 2>/dev/null | head -1 | awk '{print $2}')"

  # -- Install NPM globals (pinned) -------------------------------------------
  if [[ -n "${NPM_GLOBALS:-}" && "${INSTALL_NODEJS:-no}" == "yes" ]]; then
    info "Installing NPM globals:"
    for _p in ${NPM_GLOBALS}; do
      printf '         %s\n' "$_p"
    done
    run_in_ct "
      set -euo pipefail
      npm install -g ${NPM_GLOBALS}
      echo 'NPM globals installed'
    " "Install NPM globals (pinned)"
    ok "NPM globals installed"
  fi

  # -- Install pip packages (pinned) ------------------------------------------
  if [[ -n "${PIP_PACKAGES:-}" && "${INSTALL_BUILD_TOOLS:-no}" == "yes" ]]; then
    info "Installing pip packages:"
    for _p in ${PIP_PACKAGES}; do
      printf '         %s\n' "$_p"
    done
    run_in_ct "
      set -euo pipefail
      pip3 install --break-system-packages ${PIP_PACKAGES}
      echo 'Pip packages installed'
    " "Install pip packages (pinned)"
    ok "Pip packages installed"
  fi

  # -- Create gitlab-runner user -----------------------------------------------
  info "Setting up gitlab-runner user..."
  # shellcheck disable=SC2016  # $(hostname) expands inside the container, not here
  run_in_ct '
    set -euo pipefail

    # Create user if it does not exist (the gitlab-runner package may have created it)
    if ! id gitlab-runner &>/dev/null; then
      useradd -r -m -s /bin/bash -d /home/gitlab-runner gitlab-runner
    fi

    # Ensure home directory exists with correct ownership
    mkdir -p /home/gitlab-runner
    chown gitlab-runner:gitlab-runner /home/gitlab-runner
    chmod 750 /home/gitlab-runner

    # Add to docker group
    usermod -aG docker gitlab-runner

    # Create working directories
    mkdir -p /home/gitlab-runner/{builds,.cache,.ssh}
    chown -R gitlab-runner:gitlab-runner /home/gitlab-runner
    chmod 700 /home/gitlab-runner/.ssh

    # Generate SSH keypair for the runner
    if [[ ! -f /home/gitlab-runner/.ssh/id_ed25519 ]]; then
      su - gitlab-runner -c "ssh-keygen -t ed25519 -N \"\" -C \"gitlab-runner@$(hostname)\" -f /home/gitlab-runner/.ssh/id_ed25519"
    fi

    echo "gitlab-runner user configured"
  ' "Create gitlab-runner user"
  ok "gitlab-runner user created"

  # -- Inject SSH keys for gitlab-runner user ----------------------------------
  if [[ -n "${SSH_KEYS:-}" ]]; then
    info "Injecting SSH keys (gitlab-runner)..."
    _TMPKEYS=$(mktemp)
    echo "$SSH_KEYS" >"$_TMPKEYS"
    pct push "$CTID" "$_TMPKEYS" /tmp/authorized_keys_inject
    rm -f "$_TMPKEYS"
    pct exec "$CTID" -- bash -c '
      cat /tmp/authorized_keys_inject > /home/gitlab-runner/.ssh/authorized_keys
      chown gitlab-runner:gitlab-runner /home/gitlab-runner/.ssh/authorized_keys
      chmod 600 /home/gitlab-runner/.ssh/authorized_keys
      rm -f /tmp/authorized_keys_inject
    '
    ok "SSH keys injected for gitlab-runner user"
  fi

  # -- Sysctl tuning -----------------------------------------------------------
  if [[ -n "${SYSCTL_INOTIFY_MAX_USER_WATCHES:-}" ]]; then
    info "Applying sysctl tuning..."
    run_in_ct "
      cat > /etc/sysctl.d/99-runner-tuning.conf <<SYSCTLEOF
fs.inotify.max_user_instances = ${SYSCTL_INOTIFY_MAX_USER_INSTANCES:-65536}
fs.inotify.max_user_watches = ${SYSCTL_INOTIFY_MAX_USER_WATCHES:-4194304}
fs.inotify.max_queued_events = ${SYSCTL_INOTIFY_MAX_QUEUED_EVENTS:-8388608}
SYSCTLEOF
      sysctl --system >/dev/null 2>&1
      echo 'sysctl tuning applied'
    " "Apply sysctl tuning"
    ok "Sysctl tuning applied"
  fi

  # -- Register runner via GitLab API ------------------------------------------
  if [[ -n "${GITLAB_PAT:-}" && -n "${GITLAB_URL:-}" ]]; then
    info "Creating runner in GitLab via API..."

    # Build the API payload
    _RUNNER_TYPE="${GITLAB_RUNNER_TYPE:-instance_type}"
    _API_PAYLOAD="{\"runner_type\":\"${_RUNNER_TYPE}\",\"description\":\"${HOSTNAME}\",\"run_untagged\":${GITLAB_RUNNER_RUN_UNTAGGED:-false}"
    if [[ -n "${GITLAB_RUNNER_TAGS:-}" ]]; then
      # Convert comma-separated tags to JSON array: "a,b,c" -> ["a","b","c"]
      _TAGS_JSON=$(printf '%s' "${GITLAB_RUNNER_TAGS}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().split(',')))")
      _API_PAYLOAD="${_API_PAYLOAD},\"tag_list\":${_TAGS_JSON}"
    fi
    [[ "$_RUNNER_TYPE" == "group_type" && -n "${GITLAB_RUNNER_GROUP_ID:-}" ]] \
      && _API_PAYLOAD="${_API_PAYLOAD},\"group_id\":${GITLAB_RUNNER_GROUP_ID}"
    [[ "$_RUNNER_TYPE" == "project_type" && -n "${GITLAB_RUNNER_PROJECT_ID:-}" ]] \
      && _API_PAYLOAD="${_API_PAYLOAD},\"project_id\":${GITLAB_RUNNER_PROJECT_ID}"
    _API_PAYLOAD="${_API_PAYLOAD}}"

    # Create runner via API -- get a glrt- token back
    _API_RESPONSE=$(curl -sf \
      --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
      --header "Content-Type: application/json" \
      --data "${_API_PAYLOAD}" \
      "${GITLAB_URL}/api/v4/user/runners" 2>&1) \
      || die "Failed to create runner via GitLab API. Response: ${_API_RESPONSE}"

    _RUNNER_TOKEN=$(echo "$_API_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null) \
      || die "Failed to parse runner token from API response: ${_API_RESPONSE}"

    _RUNNER_ID=$(echo "$_API_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)

    ok "Runner created in GitLab (id: ${_RUNNER_ID})"

    # Register the runner inside the container
    info "Registering runner inside container..."
    # NOTE: With the new glrt- authentication tokens (from POST /api/v4/user/runners),
    # gitlab-runner register DOES NOT accept --tag-list, --run-untagged, --locked,
    # --access-level, --maximum-timeout, --paused, or --maintenance-note.
    # Those are managed server-side via the API call above.
    _REGISTER_CMD=(
      pct exec "$CTID" -- gitlab-runner register
      --non-interactive
      --url "${GITLAB_URL}"
      --token "${_RUNNER_TOKEN}"
      --executor "${GITLAB_RUNNER_EXECUTOR:-shell}"
      --name "${HOSTNAME}"
      --limit "${GITLAB_RUNNER_LIMIT:-1}"
      --request-concurrency "${GITLAB_RUNNER_REQUEST_CONCURRENCY:-1}"
      --output-limit "${GITLAB_RUNNER_OUTPUT_LIMIT:-8192}"
    )
    "${_REGISTER_CMD[@]}"

    ok "Runner registered"

    # Patch config.toml with concurrent setting
    pct exec "$CTID" -- bash -c "
      sed -i 's/^concurrent = .*/concurrent = ${GITLAB_RUNNER_CONCURRENT:-2}/' /etc/gitlab-runner/config.toml
    "
    ok "concurrent set to ${GITLAB_RUNNER_CONCURRENT:-2}"

    # Registration summary
    printf '\n'
    info "Runner registered successfully in GitLab:"
    printf '\n'
    info "  Runner ID:    ${_RUNNER_ID}"
    info "  Name:         ${HOSTNAME}"
    info "  Type:         ${_RUNNER_TYPE}"
    info "  Executor:     ${GITLAB_RUNNER_EXECUTOR:-shell}"
    info "  Tags:         ${GITLAB_RUNNER_TAGS:-none}"
    info "  Run untagged: ${GITLAB_RUNNER_RUN_UNTAGGED:-false}"
    info "  Concurrent:   ${GITLAB_RUNNER_CONCURRENT:-2}"
    info "  URL:          ${GITLAB_URL}/admin/runners/${_RUNNER_ID}"
    printf '\n'
  else
    warn "GITLAB_PAT or GITLAB_URL not set -- skipping auto-registration"
    warn "Register manually: gitlab-runner register --url <URL> --token <TOKEN>"
  fi

  # -- Systemd resource limits -------------------------------------------------
  info "Configuring systemd resource limits..."
  run_in_ct "
    mkdir -p /etc/systemd/system/gitlab-runner.service.d
    cat > /etc/systemd/system/gitlab-runner.service.d/resource-limits.conf <<UNITEOF
[Service]
# Budget: ${CORES} cores / ${MEMORY}MB total LXC
# Reserved for OS + Docker + Dockge: ~2 cores / ~2GB
# Runner gets the remainder
CPUQuota=${RUNNER_CPU_QUOTA:-600%}
MemoryMax=${RUNNER_MEMORY_MAX:-6G}
UNITEOF
    systemctl daemon-reload
    echo 'Systemd resource limits configured'
  " "Configure systemd resource limits"
  ok "Runner limited to CPU=${RUNNER_CPU_QUOTA:-600%}, Mem=${RUNNER_MEMORY_MAX:-6G}"

  # -- Start gitlab-runner service ---------------------------------------------
  info "Starting gitlab-runner service..."
  pct exec "$CTID" -- systemctl enable --now gitlab-runner
  sleep 2
  pct exec "$CTID" -- systemctl is-active gitlab-runner >/dev/null \
    || die "gitlab-runner service failed to start"
  ok "gitlab-runner service is running"
fi

# ==============================================================================
# PHASE 5: Health Check Endpoint
# ==============================================================================

_HEALTH_PORT="${HEALTH_PORT:-5000}"
info "Installing health check endpoint on port ${_HEALTH_PORT}..."

run_in_ct "
  cat > /usr/local/bin/container-health <<'HEALTHSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# -- consume the incoming HTTP request -----------------------------------------
while IFS= read -r line; do
  line=\"\${line%%\$'\\r'}\"
  [[ -z \"\$line\" ]] && break
done

# -- gather system info -------------------------------------------------------
_hostname='${HOSTNAME}'
_uptime_secs=\$(awk '{print int(\$1)}' /proc/uptime)
_days=\$(( _uptime_secs / 86400 ))
_hours=\$(( (_uptime_secs % 86400) / 3600 ))
_mins=\$(( (_uptime_secs % 3600) / 60 ))
_uptime=\"\${_days}d \${_hours}h \${_mins}m\"

# -- check services -----------------------------------------------------------
_overall=\"healthy\"
_services=\"\"
_sep=\"\"

check_service() {
  local name=\"\$1\" status=\"healthy\"
  if ! systemctl is-active --quiet \"\$name\" 2>/dev/null; then
    status=\"unhealthy\"
    _overall=\"degraded\"
  fi
  _services=\"\${_services}\${_sep}\\\"\${name}\\\":{\\\"status\\\":\\\"\${status}\\\"}\"
  _sep=\",\"
}

check_docker_container() {
  local name=\"\$1\" status=\"healthy\"
  local health
  health=\$(docker inspect --format '{{.State.Health.Status}}' \"\$name\" 2>/dev/null || echo \"\")
  if [[ -z \"\$health\" ]]; then
    local running
    running=\$(docker inspect --format '{{.State.Running}}' \"\$name\" 2>/dev/null || echo \"false\")
    if [[ \"\$running\" != \"true\" ]]; then
      status=\"unhealthy\"
      _overall=\"degraded\"
    fi
  elif [[ \"\$health\" != \"healthy\" ]]; then
    status=\"\$health\"
    [[ \"\$health\" == \"starting\" ]] || _overall=\"degraded\"
  fi
  _services=\"\${_services}\${_sep}\\\"\${name}\\\":{\\\"status\\\":\\\"\${status}\\\"}\"
  _sep=\",\"
}

# Docker daemon
if command -v docker >/dev/null 2>&1; then
  check_service docker
fi

# GitLab Runner (only if installed)
if command -v gitlab-runner >/dev/null 2>&1; then
  check_service gitlab-runner
fi

# Docker containers (Dockge, Kroki, etc.)
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
  while IFS= read -r cname; do
    [[ -n \"\$cname\" ]] && check_docker_container \"\$cname\"
  done < <(docker ps --format '{{.Names}}' 2>/dev/null)
fi

# -- build JSON response -------------------------------------------------------
_body=\"{\\\"status\\\":\\\"\${_overall}\\\",\\\"hostname\\\":\\\"\${_hostname}\\\",\\\"uptime\\\":\\\"\${_uptime}\\\",\\\"services\\\":{\${_services}}}\"

if [[ \"\$_overall\" == \"healthy\" ]]; then
  _code=\"200 OK\"
else
  _code=\"503 Service Unavailable\"
fi

_len=\${#_body}

# -- write HTTP response -------------------------------------------------------
printf 'HTTP/1.1 %s\r\n' \"\$_code\"
printf 'Content-Type: application/json\r\n'
printf 'Content-Length: %d\r\n' \"\$_len\"
printf 'Connection: close\r\n'
printf '\r\n'
printf '%s' \"\$_body\"
HEALTHSCRIPT

  chmod +x /usr/local/bin/container-health

  # systemd socket unit
  cat > /etc/systemd/system/container-health.socket <<SOCKETEOF
[Unit]
Description=Container Health Check Socket

[Socket]
ListenStream=${_HEALTH_PORT}
Accept=yes
ReusePort=true

[Install]
WantedBy=sockets.target
SOCKETEOF

  # systemd service unit (template, instantiated per connection)
  cat > '/etc/systemd/system/container-health@.service' <<SERVICEEOF
[Unit]
Description=Container Health Check Handler

[Service]
Type=oneshot
ExecStart=/usr/local/bin/container-health
StandardInput=socket
StandardOutput=socket
StandardError=journal
SERVICEEOF

  systemctl daemon-reload
  systemctl enable --now container-health.socket
  echo 'Health check endpoint installed'
" "Install health check endpoint"
ok "Health check listening on port ${_HEALTH_PORT}"

# ==============================================================================
# PHASE 6: UFW Firewall
# ==============================================================================

if [[ "${INSTALL_UFW:-no}" == "yes" ]]; then
  _UFW_FROM="${UFW_ALLOW_FROM:-10.0.0.0/8}"
  _UFW_PORTS="${UFW_INBOUND_PORTS:-22}"

  # Build the ufw rules dynamically
  _UFW_RULES=""
  for port in $_UFW_PORTS; do
    _UFW_RULES="${_UFW_RULES}
ufw allow from ${_UFW_FROM} to any port ${port} proto tcp"
  done

  run_in_ct "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ufw >/dev/null 2>&1

    # Reset to clean slate
    ufw --force reset >/dev/null 2>&1

    # Default policies: deny inbound, allow outbound, allow routed (Docker)
    ufw default deny incoming
    ufw default allow outgoing
    ufw default allow routed

    # Inbound rules from LAN
    ${_UFW_RULES}

    # Docker forwarding (NET_NAME defaults to eth0 inside the container)
    ufw route allow in on ${NET_NAME:-eth0} out on docker0

    # Enable
    ufw --force enable

    echo 'UFW configured'
  " "Install and configure UFW"
  ok "UFW enabled: deny inbound, allow outbound, allow ${_UFW_PORTS} from ${_UFW_FROM}"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
_IP_BARE="${IP%%/*}"

printf '\n'
printf '============================================================\n'
ok "Provisioning complete: $CTID ($HOSTNAME)"
printf '============================================================\n'

printf '\n--- What was provisioned ---\n'
info "LXC container $CTID created on ${CONTAINER_STORAGE} (${CORES} cores, ${MEMORY}MB RAM, ${DISK_SIZE}GB disk)"
info "Network: ${_IP_BARE} (bridge ${BRIDGE:-vmbr1}, VLAN ${VLAN:-none}, MTU ${MTU:-1500})"
[[ -n "${PCT_TAGS:-}" ]] && info "Proxmox tags: ${PCT_TAGS}"
if [[ -n "${SSH_KEYS:-}" ]]; then
  if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then
    info "SSH keys injected for root + gitlab-runner"
  else
    info "SSH keys injected for root"
  fi
fi
[[ "${FIX_LOCALE:-no}" == "yes" ]] && info "Locale: en_US.UTF-8"

[[ "${INSTALL_DOCKER:-no}" == "yes" ]] && {
  _DVER=$(pct exec "$CTID" -- docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  _CVER=$(pct exec "$CTID" -- docker compose version 2>/dev/null | awk '{print $NF}')
  info "Docker ${_DVER}, Compose ${_CVER} (pinned + held)"
  info "Docker daemon MTU: ${DOCKER_MTU:-1500}"
}
[[ "${INSTALL_DOCKGE:-no}" == "yes" ]] \
  && info "Dockge running on port ${DOCKGE_PORT:-5001} (pinned digest)"

if [[ -d "${_STACKS_DIR:-}" ]]; then
  for _sd in "$_STACKS_DIR"/*/; do
    _sn=$(basename "$_sd")
    [[ -f "${_sd}compose.yaml" ]] && info "Stack: ${_sn}"
  done
fi

if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then
  _GVER=$(pct exec "$CTID" -- gitlab-runner --version 2>/dev/null | head -1 | awk '{print $2}')
  info "gitlab-runner ${_GVER} (pinned + held)"
  [[ "${INSTALL_NODEJS:-no}" == "yes" ]] && info "Node.js $(pct exec "$CTID" -- node --version 2>/dev/null)"
  [[ "${INSTALL_TERRAFORM:-no}" == "yes" ]] && info "Terraform $(pct exec "$CTID" -- terraform --version 2>/dev/null | head -1 | awk '{print $2}')"
  [[ "${INSTALL_OPENTOFU:-no}" == "yes" ]] && info "OpenTofu $(pct exec "$CTID" -- tofu --version 2>/dev/null | head -1 | awk '{print $2}')"
  [[ -n "${NPM_GLOBALS:-}" ]] && info "NPM globals: $(printf '%s' "${NPM_GLOBALS}" | wc -w | tr -d ' ') packages installed"
  [[ -n "${PIP_PACKAGES:-}" ]] && info "Pip packages: ${PIP_PACKAGES}"
  info "Systemd limits: CPU=${RUNNER_CPU_QUOTA:-600%}, Mem=${RUNNER_MEMORY_MAX:-6G}"
fi

info "Health:  http://${_IP_BARE}:${HEALTH_PORT:-5000}/health"

[[ "${INSTALL_UFW:-no}" == "yes" ]] \
  && info "UFW: deny inbound, allow outbound, allow ${UFW_INBOUND_PORTS:-22} from ${UFW_ALLOW_FROM:-10.0.0.0/8}"

[[ -n "${SYSCTL_INOTIFY_MAX_USER_WATCHES:-}" ]] \
  && info "Sysctl: inotify watches=${SYSCTL_INOTIFY_MAX_USER_WATCHES}"

printf '\n--- Access ---\n'
info "Console: pct enter $CTID"
info "SSH:     ssh root@${_IP_BARE}"
info "Health:  http://${_IP_BARE}:${HEALTH_PORT:-5000}/health"
if [[ "${INSTALL_DOCKGE:-no}" == "yes" ]]; then
  info "Dockge:  http://${_IP_BARE}:${DOCKGE_PORT:-5001}"
  info "         Visit to create admin account on first login"
fi
[[ -n "${KROKI_PORT:-}" ]] \
  && info "Kroki:   http://${_IP_BARE}:${KROKI_PORT}"
[[ -n "${_RUNNER_ID:-}" ]] \
  && info "Runner:  ${GITLAB_URL}/admin/runners/${_RUNNER_ID}"

if [[ "${INSTALL_DOCKGE:-no}" == "yes" ]]; then
  printf '\n--- Stack layout ---\n'
  info "/opt/dockge/           -- Dockge itself"
  info "/opt/stacks/<name>/    -- compose.yaml per stack (Dockge manages these)"
  info "/opt/stacks/data/<name>/ -- persistent data volumes"
fi

if [[ "${INSTALL_GITLAB_RUNNER:-no}" == "yes" ]]; then
  printf '\n--- Runner SSH Public Key ---\n'
  info "Add this to deployment targets that the runner needs to reach:"
  pct exec "$CTID" -- cat /home/gitlab-runner/.ssh/id_ed25519.pub 2>/dev/null
fi
printf '\n'

printf '============================================================\n'
