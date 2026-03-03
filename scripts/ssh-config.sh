#!/usr/bin/env bash
set -euo pipefail

# ─── SSH Config for GitLab via Cloudflare Tunnel ─────────────────────────────
# Configures local ~/.ssh/config entries for accessing the GitLab instance
# through a Cloudflare Tunnel (client-side cloudflared proxy).
#
# Creates two SSH host entries:
#   1. git access  — "Host <GITLAB_DOMAIN>" for git clone/push/pull
#   2. admin access — "Host gitlab-lxc" for interactive root SSH
#
# Also adds the server's host key to ~/.ssh/known_hosts under the tunnel
# hostname so SSH doesn't prompt on first connect.
#
# Usage:
#   ./ssh-config.sh              # configure SSH
#   ./ssh-config.sh --dry-run    # preview changes without writing
#
# Requires: GITLAB_DOMAIN + LXC_HOST in .env, cloudflared installed locally
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "ERROR: ssh-config.sh failed at line ${LINENO}."' ERR

# ─── Check required commands ─────────────────────────────────────────────────
CLOUDFLARED=""
for candidate in /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared cloudflared; do
  if command -v "${candidate}" &>/dev/null; then
    CLOUDFLARED="$(command -v "${candidate}")"
    break
  fi
done

if [[ -z "${CLOUDFLARED}" ]]; then
  printf '%s\n' "ERROR: cloudflared is required but not found"
  printf '%s\n' "  Install: brew install cloudflare/cloudflare/cloudflared"
  exit 1
fi

if ! command -v ssh-keyscan &>/dev/null; then
  printf '%s\n' "ERROR: ssh-keyscan is required but not found"
  exit 1
fi

# ─── Load .env ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

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
for var in GITLAB_DOMAIN LXC_HOST; do
  if [[ -z "${!var:-}" || "${!var}" == "<"* ]]; then
    printf '%s\n' "ERROR: ${var} is missing or still a placeholder in .env"
    exit 1
  fi
done

# ─── Derive values ───────────────────────────────────────────────────────────
SSH_HOSTNAME="ssh.${GITLAB_DOMAIN}"
LXC_IP="${LXC_HOST#*@}" # strip user@ prefix (root@x.x.x.x → x.x.x.x)

SSH_CONFIG="${HOME}/.ssh/config"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

printf '%s\n' "SSH Config Setup for GitLab via Cloudflare Tunnel"
printf '\n'
printf '%s\n' "  GitLab domain:  ${GITLAB_DOMAIN}"
printf '%s\n' "  SSH hostname:   ${SSH_HOSTNAME}"
printf '%s\n' "  LXC IP:         ${LXC_IP}"
printf '%s\n' "  cloudflared:    ${CLOUDFLARED}"
printf '\n'

# ─── Ensure ~/.ssh exists ────────────────────────────────────────────────────
if [[ ! -d "${HOME}/.ssh" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s\n' "[DRY RUN] Would create ${HOME}/.ssh"
  else
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
  fi
fi

# ─── Helper: add block to ssh config if not present ──────────────────────────
add_ssh_block() {
  local marker="$1"
  local block="$2"
  local description="$3"

  if [[ -f "${SSH_CONFIG}" ]] && grep -qF "${marker}" "${SSH_CONFIG}"; then
    printf '%s\n' "SKIP: ${description} (already in ${SSH_CONFIG})"
  elif [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s\n' "[DRY RUN] Would add to ${SSH_CONFIG}:"
    printf '\n'
    printf '%s\n' "${block}"
    printf '\n'
  else
    # Add a blank line separator if file exists and doesn't end with newline
    if [[ -f "${SSH_CONFIG}" ]] && [[ -s "${SSH_CONFIG}" ]]; then
      printf '\n' >>"${SSH_CONFIG}"
    fi
    printf '%s\n' "${block}" >>"${SSH_CONFIG}"
    printf '%s\n' "ADDED: ${description}"
  fi
}

# ─── 1. Git access (git clone/push/pull via tunnel) ─────────────────────────
GIT_BLOCK="# GitLab git access via Cloudflare Tunnel
Host ${GITLAB_DOMAIN}
    ProxyCommand ${CLOUDFLARED} access ssh --hostname ssh.%h
    User git"

add_ssh_block "Host ${GITLAB_DOMAIN}" "${GIT_BLOCK}" "Git access (Host ${GITLAB_DOMAIN})"

# ─── 2. Admin root SSH access via tunnel ─────────────────────────────────────
ADMIN_BLOCK="# GitLab LXC admin access via Cloudflare Tunnel
Host gitlab-lxc
    HostName ${SSH_HOSTNAME}
    ProxyCommand ${CLOUDFLARED} access ssh --hostname %h
    User root"

add_ssh_block "Host gitlab-lxc" "${ADMIN_BLOCK}" "Admin access (Host gitlab-lxc)"

# ─── 3. Add host key to known_hosts ─────────────────────────────────────────
if [[ -f "${KNOWN_HOSTS}" ]] && grep -qF "${SSH_HOSTNAME}" "${KNOWN_HOSTS}"; then
  printf '%s\n' "SKIP: Host key for ${SSH_HOSTNAME} (already in ${KNOWN_HOSTS})"
else
  printf '\n'
  printf '%s\n' "Scanning host key from ${LXC_IP}..."

  HOST_KEY=$(ssh-keyscan -t ed25519 -p 22 "${LXC_IP}" 2>/dev/null | head -1)

  if [[ -z "${HOST_KEY}" ]]; then
    printf '%s\n' "WARNING: Could not scan host key from ${LXC_IP}"
    printf '%s\n' "  You may be prompted to verify the host key on first SSH connect."
  else
    # Replace the IP with the tunnel hostname
    TUNNEL_KEY="${SSH_HOSTNAME} ${HOST_KEY#* }"

    if [[ "${DRY_RUN}" == "true" ]]; then
      printf '%s\n' "[DRY RUN] Would add to ${KNOWN_HOSTS}:"
      printf '%s\n' "  ${TUNNEL_KEY}"
    else
      printf '%s\n' "${TUNNEL_KEY}" >>"${KNOWN_HOSTS}"
      printf '%s\n' "ADDED: Host key for ${SSH_HOSTNAME}"
    fi
  fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────
printf '\n'
printf '%s\n' "Done. You can now use:"
printf '%s\n' "  git clone git@${GITLAB_DOMAIN}:<group>/<project>.git"
printf '%s\n' "  ssh gitlab-lxc"
