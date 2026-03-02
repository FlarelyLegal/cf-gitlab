#!/usr/bin/env bash
set -euo pipefail

# ─── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ Setup failed at line ${LINENO}. Check output above for details."' ERR

# ─── Load secrets ─────────────────────────────────────────────────────────────
if [[ ! -f /root/.secrets/gitlab.env ]]; then
  printf '%s\n' "✗ Missing /root/.secrets/gitlab.env — run deploy.sh first."
  exit 1
fi
set -a
# shellcheck source=/dev/null
source /root/.secrets/gitlab.env
set +a
printf '%s\n' "✓ Secrets loaded"

# ─── Derived configuration ───────────────────────────────────────────────────
export EXTERNAL_URL="https://${GITLAB_DOMAIN}"
# ──────────────────────────────────────────────────────────────────────────────

if ${DRY_RUN}; then
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  Domain:         ${GITLAB_DOMAIN}"
  printf '%s\n' "  Registry:       ${REGISTRY_DOMAIN}"
  printf '%s\n' "  Pages:          ${PAGES_DOMAIN}"
  printf '%s\n' "  Root email:     ${GITLAB_ROOT_EMAIL}"
  printf '%s\n' "  Cert email:     ${CERT_EMAIL}"
  printf '%s\n' "  Org:            ${ORG_NAME} — ${ORG_URL}"
  printf '%s\n' "  SSH allow:      ${SSH_ALLOW_CIDR}"
  printf '%s\n' "  Internal DNS:   ${INTERNAL_DNS}"
  printf '%s\n' "  OIDC issuer:    ${OIDC_ISSUER:0:40}..."
  printf '%s\n' "  GitHub app:     ${GITHUB_APP_ID}"
  printf '%s\n' "  R2 buckets:     ${R2_BUCKET_PREFIX}-{artifacts,lfs,uploads,...} (10 buckets)"
  printf '%s\n' "  Backup bucket:  ${R2_BACKUP_BUCKET:-${R2_BUCKET_PREFIX}-backups}"
  printf '%s\n' "  Runner:         ${RUNNER_NAME} (${RUNNER_TAGS})"
  printf '\n'
  printf '%s\n' "  Would perform:"
  printf '%s\n' "    1. Set MOTD"
  printf '%s\n' "    2. Configure Cloudflare NTS (chrony)"
  printf '%s\n' "    3. Install packages + configure UFW (80, 443, SSH from ${SSH_ALLOW_CIDR})"
  printf '%s\n' "    4. Request TLS certs (${GITLAB_DOMAIN}, ${REGISTRY_DOMAIN}, ${PAGES_DOMAIN})"
  printf '%s\n' "    5. Add GitLab CE APT repository"
  printf '%s\n' "    6. Pre-seed /etc/gitlab/gitlab.rb (nginx, OmniAuth, registry, pages, R2)"
  printf '%s\n' "    7. Install GitLab CE"
  printf '%s\n' "    8. Seed database (root user)"
  printf '%s\n' "    9. Install certbot renewal hook"
  printf '%s\n' "   10. Install registry GC cron (Sunday 3am)"
  printf '%s\n' "   11. Install daily backup cron (2am -> R2)"
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to execute."
  exit 0
fi

# ─── Step 1: MOTD ────────────────────────────────────────────────────────────
printf '%s\n' "→ Setting MOTD..."
bash /tmp/gitlab-motd.sh
printf '%s\n' "✓ MOTD set"

# ─── Step 2: Chrony NTS ──────────────────────────────────────────────────
printf '%s\n' "→ Configuring Cloudflare NTS time sync..."
bash /tmp/gitlab-timing.sh
printf '%s\n' "✓ Chrony configured"

# ─── Step 3: Packages + UFW Firewall ─────────────────────────────────────
printf '%s\n' "→ Installing packages (ufw, curl, certbot)..."
apt-get update -qq
apt-get install -y -qq ufw curl certbot python3-certbot-dns-cloudflare >/dev/null
printf '%s\n' "✓ Packages installed"

printf '%s\n' "→ Configuring UFW firewall..."
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow from "${SSH_ALLOW_CIDR}" to any port 22 proto tcp >/dev/null
printf '%s\n' "y" | ufw enable >/dev/null
printf '%s\n' "✓ UFW enabled (default deny, 80, 443, SSH from ${SSH_ALLOW_CIDR})"

# ─── Step 4: TLS Certificates ────────────────────────────────────────────
if [[ ! -f /root/.secrets/cloudflare.ini ]]; then
  printf '%s\n' "✗ Missing /root/.secrets/cloudflare.ini — run deploy.sh first."
  exit 1
fi

printf '%s\n' "→ Requesting TLS certificate for ${GITLAB_DOMAIN}..."
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d "${GITLAB_DOMAIN}" \
  --non-interactive --agree-tos --keep-until-expiring \
  -m "${CERT_EMAIL}"
printf '%s\n' "✓ TLS certificate obtained for ${GITLAB_DOMAIN}"

printf '%s\n' "→ Requesting TLS certificate for ${REGISTRY_DOMAIN}..."
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d "${REGISTRY_DOMAIN}" \
  --non-interactive --agree-tos --keep-until-expiring \
  -m "${CERT_EMAIL}"
printf '%s\n' "✓ TLS certificate obtained for ${REGISTRY_DOMAIN}"

printf '%s\n' "→ Requesting TLS certificate for ${PAGES_DOMAIN} (+ wildcard)..."
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  -d "${PAGES_DOMAIN}" \
  -d "*.${PAGES_DOMAIN}" \
  --non-interactive --agree-tos --keep-until-expiring \
  -m "${CERT_EMAIL}"
printf '%s\n' "✓ TLS certificate obtained for ${PAGES_DOMAIN}"

# ─── Step 5: Add GitLab CE Repository ────────────────────────────────────
printf '%s\n' "→ Adding GitLab CE APT repository..."
curl -fsSL "https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh" -o /tmp/gitlab-repo.sh
bash /tmp/gitlab-repo.sh
rm -f /tmp/gitlab-repo.sh
printf '%s\n' "✓ GitLab CE repo added"

# ─── Step 6: Pre-seed gitlab.rb for LXC ──────────────────────────────────────
# GitLab creates /etc/gitlab/gitlab.rb during install — we pre-create it so
# the installer picks up our overrides on the first reconfigure.
mkdir -p /etc/gitlab

# Escape values for safe embedding in Ruby double-quoted strings.
ruby_escape() {
  local value="${1-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\#/\\#}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//\`/\\\`}
  printf '%s' "${value}"
}

GITLAB_DOMAIN_RB="$(ruby_escape "${GITLAB_DOMAIN}")"
REGISTRY_DOMAIN_RB="$(ruby_escape "${REGISTRY_DOMAIN}")"
PAGES_DOMAIN_RB="$(ruby_escape "${PAGES_DOMAIN}")"
INTERNAL_DNS_RB="$(ruby_escape "${INTERNAL_DNS}")"
OIDC_ISSUER_RB="$(ruby_escape "${OIDC_ISSUER}")"
OIDC_CLIENT_ID_RB="$(ruby_escape "${OIDC_CLIENT_ID}")"
OIDC_CLIENT_SECRET_RB="$(ruby_escape "${OIDC_CLIENT_SECRET}")"
GITHUB_APP_ID_RB="$(ruby_escape "${GITHUB_APP_ID}")"
GITHUB_APP_SECRET_RB="$(ruby_escape "${GITHUB_APP_SECRET}")"
R2_ENDPOINT_RB="$(ruby_escape "${R2_ENDPOINT}")"
R2_ACCESS_KEY_RB="$(ruby_escape "${R2_ACCESS_KEY}")"
R2_SECRET_KEY_RB="$(ruby_escape "${R2_SECRET_KEY}")"
R2_BUCKET_PREFIX_RB="$(ruby_escape "${R2_BUCKET_PREFIX}")"
R2_BACKUP_BUCKET_RB="$(ruby_escape "${R2_BACKUP_BUCKET:-${R2_BUCKET_PREFIX}-backups}")"

cat >/etc/gitlab/gitlab.rb <<RUBY
external_url "https://${GITLAB_DOMAIN_RB}"

# LXC: cannot modify kernel parameters from inside a container
package["modify_kernel_parameters"] = false

# We manage TLS via certbot, not GitLab's built-in Let's Encrypt
letsencrypt["enable"] = false
nginx["ssl_certificate"] = "/etc/letsencrypt/live/${GITLAB_DOMAIN_RB}/fullchain.pem"
nginx["ssl_certificate_key"] = "/etc/letsencrypt/live/${GITLAB_DOMAIN_RB}/privkey.pem"

# Redirect HTTP → HTTPS
nginx["redirect_http_to_https"] = true
nginx["redirect_http_to_https_port"] = 80

# ── Nginx Hardening ──────────────────────────────────────────────────────────
nginx["worker_processes"] = "auto"
nginx["hsts_max_age"] = 63072000
nginx["hsts_include_subdomains"] = true
nginx["custom_gitlab_server_config"] = <<~CONF
  add_header X-Content-Type-Options nosniff always;
  add_header X-Frame-Options SAMEORIGIN always;
  add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

  ssl_stapling on;
  ssl_stapling_verify on;
  resolver ${INTERNAL_DNS_RB} valid=300s;
  resolver_timeout 5s;

  set_real_ip_from 127.0.0.1/32;
  real_ip_header X-Forwarded-For;
  real_ip_recursive on;
CONF
nginx["gzip_comp_level"] = "3"

# ── OmniAuth ─────────────────────────────────────────────────────────────────
gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_block_auto_created_users'] = false
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']
# Auto sign-in is configured by sso-only.sh after verifying SSO works:
# gitlab_rails['omniauth_auto_sign_in_with_provider'] = 'openid_connect'
gitlab_rails['omniauth_providers'] = [
  {
    name: "openid_connect",
    label: "Cloudflare Access",
    args: {
      name: "openid_connect",
      scope: ["openid", "profile", "email"],
      response_type: "code",
      issuer: "${OIDC_ISSUER_RB}",
      discovery: true,
      client_auth_method: "query",
      uid_field: "sub",
      pkce: true,
      client_options: {
        identifier: "${OIDC_CLIENT_ID_RB}",
        secret: "${OIDC_CLIENT_SECRET_RB}",
        redirect_uri: "https://${GITLAB_DOMAIN_RB}/users/auth/openid_connect/callback"
      }
    }
  },
  {
    name: "github",
    app_id: "${GITHUB_APP_ID_RB}",
    app_secret: "${GITHUB_APP_SECRET_RB}",
    args: { scope: "read:user,read:org,repo" }
  }
]

# ── Container Registry ───────────────────────────────────────────────────────
registry_external_url "https://${REGISTRY_DOMAIN_RB}"
registry_nginx["ssl_certificate"] = "/etc/letsencrypt/live/${REGISTRY_DOMAIN_RB}/fullchain.pem"
registry_nginx["ssl_certificate_key"] = "/etc/letsencrypt/live/${REGISTRY_DOMAIN_RB}/privkey.pem"

# ── GitLab Pages ─────────────────────────────────────────────────────────────
pages_external_url "https://${PAGES_DOMAIN_RB}"
pages_nginx["ssl_certificate"] = "/etc/letsencrypt/live/${PAGES_DOMAIN_RB}/fullchain.pem"
pages_nginx["ssl_certificate_key"] = "/etc/letsencrypt/live/${PAGES_DOMAIN_RB}/privkey.pem"
gitlab_pages["redirect_http"] = true

# ── R2 Object Storage (separate bucket per object type) ──────────────────────
gitlab_rails['object_store']['enabled'] = true
gitlab_rails['object_store']['proxy_download'] = true
gitlab_rails['object_store']['connection'] = {
  'provider' => 'AWS',
  'endpoint' => "${R2_ENDPOINT_RB}",
  'aws_access_key_id' => "${R2_ACCESS_KEY_RB}",
  'aws_secret_access_key' => "${R2_SECRET_KEY_RB}",
  'aws_signature_version' => 4,
  'path_style' => true,
  'region' => 'auto'
}
gitlab_rails['object_store']['objects']['artifacts']['bucket']        = "${R2_BUCKET_PREFIX_RB}-artifacts"
gitlab_rails['object_store']['objects']['external_diffs']['bucket']   = "${R2_BUCKET_PREFIX_RB}-external-diffs"
gitlab_rails['object_store']['objects']['lfs']['bucket']              = "${R2_BUCKET_PREFIX_RB}-lfs"
gitlab_rails['object_store']['objects']['uploads']['bucket']          = "${R2_BUCKET_PREFIX_RB}-uploads"
gitlab_rails['object_store']['objects']['packages']['bucket']         = "${R2_BUCKET_PREFIX_RB}-packages"
gitlab_rails['object_store']['objects']['dependency_proxy']['bucket'] = "${R2_BUCKET_PREFIX_RB}-dependency-proxy"
gitlab_rails['object_store']['objects']['terraform_state']['bucket']  = "${R2_BUCKET_PREFIX_RB}-terraform-state"
gitlab_rails['object_store']['objects']['pages']['bucket']            = "${R2_BUCKET_PREFIX_RB}-pages"
gitlab_rails['object_store']['objects']['ci_secure_files']['bucket']  = "${R2_BUCKET_PREFIX_RB}-ci-secure-files"

# ── Backup archive upload to R2 ──────────────────────────────────────────────
gitlab_rails['backup_upload_connection'] = {
  'provider'                      => 'AWS',
  'region'                        => 'auto',
  'endpoint'                      => "${R2_ENDPOINT_RB}",
  'aws_access_key_id'             => "${R2_ACCESS_KEY_RB}",
  'aws_secret_access_key'         => "${R2_SECRET_KEY_RB}",
  'aws_signature_version'         => 4,
  'path_style'                    => true,
  'enable_signature_v4_streaming' => false
}
gitlab_rails['backup_upload_remote_directory'] = "${R2_BACKUP_BUCKET_RB}"
gitlab_rails['backup_keep_time'] = 604800

# ── Health check monitoring whitelist ─────────────────────────────────────────
# Allow /-/health, /-/liveness, /-/readiness from any IP.
# Traffic already gates through Cloudflare Tunnel — no need to restrict by source IP.
gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0', '::/0']
RUBY
printf '%s\n' "✓ Pre-seeded /etc/gitlab/gitlab.rb"

# ─── Step 7: Install GitLab CE ───────────────────────────────────────────
printf '%s\n' "→ Installing GitLab CE (this may take several minutes)..."
# Validate password: auto-generate if placeholder, too short, or missing.
if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]] \
  || [[ "${GITLAB_ROOT_PASSWORD}" == *"<"* ]] \
  || [[ ${#GITLAB_ROOT_PASSWORD} -lt 12 ]]; then
  GITLAB_ROOT_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=')"
  export GITLAB_ROOT_PASSWORD
  printf '%s\n' "⚠ Password missing or too weak — auto-generated (saved to /root/.secrets/initial_root_password)"
fi

# Install. If the DB seed rejects the password, fall back to a random one.
if ! apt-get install -y gitlab-ce; then
  printf '%s\n' "⚠ Install hit a seed error. Generating a policy-safe password and retrying..."
  GITLAB_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
  export GITLAB_ROOT_PASSWORD
  printf '%s\n' "  New generated password saved to /root/.secrets/initial_root_password"
  dpkg --configure gitlab-ce
fi
printf '%s\n' "✓ GitLab CE installed"

# Persist the root password to a secure file (especially important for auto-generated ones)
printf '%s\n' "${GITLAB_ROOT_PASSWORD}" >/root/.secrets/initial_root_password
chmod 600 /root/.secrets/initial_root_password

# ─── Step 8: Ensure DB seed (creates admin user) ────────────────────────────
# Safety net: if the install's seed was skipped entirely, this creates the admin.
# Skip if any admin user already exists (username may have been changed from 'root').
printf '%s\n' "→ Checking admin user exists..."
ADMIN_ID=$(gitlab-psql -t -c "SELECT id FROM users WHERE admin = true LIMIT 1;" 2>/dev/null | tr -d ' ')
if [[ -n "${ADMIN_ID}" && "${ADMIN_ID}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "✓ Admin user exists (ID: ${ADMIN_ID}) — skipping seed"
else
  printf '%s\n' "→ Seeding database (creating admin user)..."
  gitlab-rake db:seed_fu
  printf '%s\n' "✓ Database seeded"
fi

# ─── Step 9: Certbot renewal hook ────────────────────────────────────────────
# Reload GitLab nginx after cert renewal so it picks up the new cert.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/gitlab-nginx.sh <<'HOOK'
#!/usr/bin/env bash
gitlab-ctl hup nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/gitlab-nginx.sh
printf '%s\n' "✓ Certbot renewal hook installed"

# ─── Step 10: Registry Garbage Collection cron ─────────────────────────────────
printf '%s\n' "→ Installing weekly registry GC cron..."
cat >/etc/cron.d/registry-gc <<'CRON'
# Weekly registry garbage collection (Sunday 3am)
0 3 * * 0 root /usr/bin/gitlab-ctl registry-garbage-collect -m >> /var/log/gitlab/registry-gc.log 2>&1
CRON
printf '%s\n' "✓ Registry GC cron installed (Sunday 3am)"

# Logrotate for the GC log (weekly, keep 4 rotations, compress old files)
cat >/etc/logrotate.d/registry-gc <<'LOGROTATE'
/var/log/gitlab/registry-gc.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
LOGROTATE
printf '%s\n' "✓ Registry GC logrotate installed"

# ─── Step 11: Daily backup cron ───────────────────────────────────────────────
printf '%s\n' "→ Installing daily backup cron..."

cat >/usr/local/bin/gitlab-backup-all <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# Daily GitLab backup: DB + repos → R2, config files → /var/opt/gitlab/backups/
LOG="/var/log/gitlab/backup.log"
exec >> "${LOG}" 2>&1
printf '\n'
printf '%s\n' "═══ Backup started: $(date -Iseconds) ═══"

# 1. GitLab backup (DB + repos �� tar → upload to R2 via backup_upload_connection)
/opt/gitlab/bin/gitlab-backup create CRON=1

# 2. Back up critical config files alongside the backup archives
CONFIG_ARCHIVE="/var/opt/gitlab/backups/$(date +%s)_config_backup.tar.gz"
tar -czf "${CONFIG_ARCHIVE}" \
  /etc/gitlab/gitlab-secrets.json \
  /etc/gitlab/gitlab.rb \
  2>/dev/null || true
chmod 600 "${CONFIG_ARCHIVE}"

printf '%s\n' "═══ Backup finished: $(date -Iseconds) ═══"
BACKUP_SCRIPT
chmod +x /usr/local/bin/gitlab-backup-all

cat >/etc/cron.d/gitlab-backup <<'CRON'
# Daily GitLab backup (2am) — DB + repos to R2, config files to local archive
0 2 * * * root /usr/local/bin/gitlab-backup-all
CRON
printf '%s\n' "✓ Daily backup cron installed (2am)"

# Logrotate for backup log
cat >/etc/logrotate.d/gitlab-backup <<'LOGROTATE'
/var/log/gitlab/backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
LOGROTATE
printf '%s\n' "✓ Backup logrotate installed"

# ─── Done ─────────────────────────────────────────────────────────────────
trap - ERR
printf '\n'
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  GitLab CE is running at https://${GITLAB_DOMAIN}"
printf '%s\n' "  Registry:  https://${REGISTRY_DOMAIN}"
printf '%s\n' "  Pages:     https://${PAGES_DOMAIN}"
printf '%s\n' "  Login:     root / ${GITLAB_ROOT_EMAIL}"
printf '%s\n' "  Password:  cat /root/.secrets/initial_root_password"
printf '%s\n' "════════════════════════════════════════════════════"
