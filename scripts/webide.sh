#!/usr/bin/env bash
set -euo pipefail

# ─── Web IDE Extension Host Setup ────────────────────────────────────────────
# Configures a custom extension host domain for the GitLab Web IDE so that
# VS Code static assets are served from the GitLab instance itself instead of
# the default cdn.web-ide.gitlab-static.net.
#
# What it does:
#   1. Requests a wildcard TLS certificate for *.webide.<GITLAB_DOMAIN>
#   2. Creates an nginx server block to proxy /assets/ to Workhorse
#   3. Adds the custom_nginx_config include to gitlab.rb (if not present)
#   4. Reconfigures GitLab
#
# After running this script, set the extension host domain in:
#   Admin → Settings → General → Web IDE → Extension host domain
#
# Prerequisites:
#   - DNS: CNAME  webide.<GITLAB_DOMAIN>    → <GITLAB_DOMAIN>
#   - DNS: CNAME  *.webide.<GITLAB_DOMAIN>  → webide.<GITLAB_DOMAIN>
#   - Cloudflare Tunnel route for *.webide.<GITLAB_DOMAIN>
#
# Note: If using Cloudflare Access or WAF rules, ensure *.webide.<GITLAB_DOMAIN>
# is excluded or allowed — the extension host serves static assets and must be
# reachable without authentication.
#
# Usage:
#   scripts/webide.sh              # configure
#   scripts/webide.sh --dry-run    # preview changes
# ─────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ──────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Web IDE setup failed at line ${LINENO}. Check output above."' ERR

# SSH/SCP options
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o BatchMode=yes)

# ─── Resolve paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  printf '%s\n' "✗ Missing ${ENV_FILE}. Copy .env.example and fill in real values."
  exit 1
fi

# ─── Load .env ───────────────────────────────────────────────────────────────
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# ─── Validate required variables ─────────────────────────────────────────────
for var in LXC_HOST GITLAB_DOMAIN CERT_EMAIL; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "✗ Missing ${var} in .env"
    exit 1
  fi
done

# ─── Derive webide domain ───────────────────────────────────────────────────
WEBIDE_DOMAIN="webide.${GITLAB_DOMAIN}"

printf '%s\n' "── Web IDE Extension Host Setup ──"
printf '%s\n' "  GitLab:       https://${GITLAB_DOMAIN}"
printf '%s\n' "  Extension:    ${WEBIDE_DOMAIN}"
printf '%s\n' "  Wildcard:     *.${WEBIDE_DOMAIN}"
printf '%s\n' "  Target:       ${LXC_HOST}"
printf '\n'

# ─── Test SSH ────────────────────────────────────────────────────────────────
printf '%s\n' "→ Testing SSH connection..."
if ! ssh -o ConnectTimeout=5 "${LXC_HOST}" 'true' 2>/dev/null; then
  printf '%s\n' "✗ Cannot reach ${LXC_HOST} via SSH."
  exit 1
fi
printf '%s\n' "✓ SSH connected"

# ─── Dry run ─────────────────────────────────────────────────────────────────
if ${DRY_RUN}; then
  printf '\n'
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  Would perform:"
  printf '%s\n' "    1. Request TLS cert for ${WEBIDE_DOMAIN} + *.${WEBIDE_DOMAIN}"
  printf '%s\n' "    2. Create /etc/gitlab/nginx-custom/webide.conf"
  printf '%s\n' "    3. Add custom_nginx_config include to /etc/gitlab/gitlab.rb"
  printf '%s\n' "    4. Run gitlab-ctl reconfigure"
  printf '\n'

  # Check current state
  # shellcheck disable=SC2029  # intentional client-side expansion
  CERT_EXISTS=$(ssh "${SSH_OPTS[@]}" "${LXC_HOST}" \
    "test -f /etc/letsencrypt/live/${WEBIDE_DOMAIN}/fullchain.pem && printf 'yes' || printf 'no'")
  # shellcheck disable=SC2029  # intentional client-side expansion
  NGINX_EXISTS=$(ssh "${SSH_OPTS[@]}" "${LXC_HOST}" \
    "test -f /etc/gitlab/nginx-custom/webide.conf && printf 'yes' || printf 'no'")
  INCLUDE_EXISTS=$(ssh "${SSH_OPTS[@]}" "${LXC_HOST}" \
    "grep -q 'custom_nginx_config' /etc/gitlab/gitlab.rb 2>/dev/null && printf 'yes' || printf 'no'")

  printf '%s\n' "  Current state:"
  printf '%s\n' "    TLS cert:           ${CERT_EXISTS}"
  printf '%s\n' "    nginx config:       ${NGINX_EXISTS}"
  printf '%s\n' "    gitlab.rb include:  ${INCLUDE_EXISTS}"
  printf '\n'
  printf '%s\n' "  After running, set the extension host domain in:"
  printf '%s\n' "    Admin → Settings → General → Web IDE → ${WEBIDE_DOMAIN}"
  printf '\n'
  printf '%s\n' "  ⚠ If using Cloudflare Access or WAF rules, ensure *.${WEBIDE_DOMAIN}"
  printf '%s\n' "    is excluded or allowed (serves static assets, no auth required)."
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to apply."
  exit 0
fi

# ─── 1. TLS Certificate ─────────────────────────────────────────────────────
printf '%s\n' "→ [1/4] Requesting TLS certificate for *.${WEBIDE_DOMAIN}..."
# shellcheck disable=SC2029  # intentional client-side expansion
ssh "${SSH_OPTS[@]}" "${LXC_HOST}" "certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d '${WEBIDE_DOMAIN}' \
  -d '*.${WEBIDE_DOMAIN}' \
  --non-interactive --agree-tos --keep-until-expiring \
  -m '${CERT_EMAIL}'"
printf '%s\n' "✓ TLS certificate ready"

# ─── 2. Nginx Server Block ──────────────────────────────────────────────────
printf '%s\n' "→ [2/4] Writing /etc/gitlab/nginx-custom/webide.conf..."
ssh "${SSH_OPTS[@]}" "${LXC_HOST}" "mkdir -p /etc/gitlab/nginx-custom"

# Use printf to write the config (avoids heredoc escaping issues over SSH)
# shellcheck disable=SC2029  # intentional client-side expansion
ssh "${SSH_OPTS[@]}" "${LXC_HOST}" "printf '%s\n' 'server {
  listen *:443 ssl;
  server_name *.${WEBIDE_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${WEBIDE_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${WEBIDE_DOMAIN}/privkey.pem;

  access_log  /var/log/gitlab/nginx/webide_access.log gitlab_access;
  error_log   /var/log/gitlab/nginx/webide_error.log;

  location /assets/ {
    client_max_body_size 0;
    gzip off;

    proxy_read_timeout      300;
    proxy_connect_timeout   300;
    proxy_redirect          off;

    proxy_http_version 1.1;

    proxy_set_header    Host                \$http_host;
    proxy_set_header    X-Real-IP           \$remote_addr;
    proxy_set_header    X-Forwarded-For     \$remote_addr;
    proxy_set_header    X-Forwarded-Proto   \$scheme;

    proxy_pass http://gitlab-workhorse;
  }
}' > /etc/gitlab/nginx-custom/webide.conf"
printf '%s\n' "✓ Nginx config written"

# ─── 3. gitlab.rb Include ───────────────────────────────────────────────────
printf '%s\n' "→ [3/4] Checking gitlab.rb for custom_nginx_config..."
INCLUDE_EXISTS=$(ssh "${SSH_OPTS[@]}" "${LXC_HOST}" \
  "grep -q 'custom_nginx_config' /etc/gitlab/gitlab.rb 2>/dev/null && printf 'yes' || printf 'no'")

if [[ "${INCLUDE_EXISTS}" == "yes" ]]; then
  printf '%s\n' "✓ custom_nginx_config already present in gitlab.rb"
else
  printf '%s\n' "→ Adding custom_nginx_config to gitlab.rb..."
  ssh "${SSH_OPTS[@]}" "${LXC_HOST}" "sed -i '/^nginx\[\"gzip_comp_level\"\]/a\\
\\
# ── Web IDE extension host ──────────────────────────────────────────────────\\
nginx['\''custom_nginx_config'\''] = \"include /etc/gitlab/nginx-custom/*.conf;\"' /etc/gitlab/gitlab.rb"
  printf '%s\n' "✓ Added to gitlab.rb"
fi

# ─── 4. Reconfigure ─────────────────────────────────────────────────────────
printf '%s\n' "→ [4/4] Reconfiguring GitLab..."
ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10 "${LXC_HOST}" \
  "gitlab-ctl reconfigure >/tmp/gitlab-reconfigure-webide.log 2>&1" || {
  printf '%s\n' "✗ Reconfigure failed. Check: ssh ${LXC_HOST} 'cat /tmp/gitlab-reconfigure-webide.log'"
  exit 1
}

# Verify nginx is running
NGINX_STATUS=$(ssh "${SSH_OPTS[@]}" "${LXC_HOST}" \
  "gitlab-ctl status nginx 2>&1 | head -1")
printf '%s\n' "  ${NGINX_STATUS}"

if [[ "${NGINX_STATUS}" != *"run: nginx"* ]]; then
  printf '%s\n' "⚠ Nginx may not be running. Checking config and restarting..."
  ssh "${SSH_OPTS[@]}" "${LXC_HOST}" \
    "/opt/gitlab/embedded/sbin/nginx -t -c /var/opt/gitlab/nginx/conf/nginx.conf 2>&1"
  ssh "${SSH_OPTS[@]}" "${LXC_HOST}" "gitlab-ctl restart nginx"
fi

printf '%s\n' "✓ GitLab reconfigured"

# ─── Done ────────────────────────────────────────────────────────────────────
trap - ERR
printf '\n'
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  Web IDE extension host configured"
printf '%s\n' "  Domain:  ${WEBIDE_DOMAIN}"
printf '%s\n' "  Cert:    /etc/letsencrypt/live/${WEBIDE_DOMAIN}/"
printf '%s\n' "  Nginx:   /etc/gitlab/nginx-custom/webide.conf"
printf '\n'
printf '%s\n' "  Next step — set the domain in GitLab:"
printf '%s\n' "    Admin → Settings → General → Web IDE"
printf '%s\n' "    Extension host domain: ${WEBIDE_DOMAIN}"
printf '\n'
printf '%s\n' "  ⚠ If using Cloudflare Access or WAF rules, ensure"
printf '%s\n' "    *.${WEBIDE_DOMAIN} is allowed (static assets, no auth)."
printf '%s\n' "════════════════════════════════════════════════════"
