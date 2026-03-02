# cf-gitlab

[![Cloudflare](https://img.shields.io/badge/Cloudflare-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/)
[![Cloudflare Workers](https://img.shields.io/badge/Workers-F38020?logo=cloudflareworkers&logoColor=white)](https://developers.cloudflare.com/workers/)
[![Cloudflare R2](https://img.shields.io/badge/R2-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/r2/)
[![Zero Trust](https://img.shields.io/badge/Zero%20Trust-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/)
[![GitLab CE](https://img.shields.io/badge/GitLab%20CE-FC6D26?logo=gitlab&logoColor=white)](https://about.gitlab.com/)
[![Debian 13](https://img.shields.io/badge/Debian%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![Shell](https://img.shields.io/badge/Shell-4EAA25?logo=gnubash&logoColor=white)](#)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%203.0-blue.svg)](LICENSE)

Deploys a fully configured GitLab CE instance on a Debian 13 LXC with:

- Let's Encrypt TLS via Certbot (Cloudflare DNS-01, auto-renewing) for GitLab, Container Registry, and Pages
- Nginx hardening (HSTS, security headers, OCSP stapling, gzip)
- OmniAuth SSO (Cloudflare Access OIDC + GitHub OAuth)
- Container Registry on a dedicated subdomain
- GitLab Pages with wildcard cert
- Cloudflare R2 object storage (10 separate buckets — keeps artifacts, LFS, uploads, backups, etc. off local disk)
- Weekly registry garbage collection + Docker image prune crons
- UFW firewall (default deny, SSH restricted to internal network)
- CDN WAF + cache rule provisioning via Cloudflare API

All deployment scripts support `--dry-run` to preview changes without modifying anything.
`validate.sh` is read-only by design and does not need `--dry-run`.

---

## Prerequisites

Complete these **before** running any scripts.

### 1. Debian 13 LXC

Create a Proxmox LXC (or similar) with:

- **OS:** Debian 13 (Trixie)
- **Resources:** 8 CPU, 16 GB RAM, 50 GB disk (minimum)
- **Network:** Static IP on your LAN, DNS resolver configured
- **SSH:** Root login enabled, your public key in `/root/.ssh/authorized_keys`

Verify SSH access from your local machine:

```bash
ssh root@<LXC_IP> 'hostname && cat /etc/os-release | grep PRETTY_NAME'
```

### 2. Cloudflare Tunnel

Install `cloudflared` on the LXC and create a tunnel. See [Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/).

> The tunnel serves two purposes: **public hostnames** for GitLab, the container registry, and
> Git-over-SSH (optional, for external access), and a **VPC Service binding** that the CDN Worker
> uses to reach the origin without exposing it to the public internet.

```bash
# On the LXC:

# Add Cloudflare GPG key + apt repository
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
  | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared

# Install as a systemd service (token from Zero Trust dashboard)
cloudflared service install <TUNNEL_TOKEN>
```

Note the **Tunnel ID** — you'll need it for DNS records in the next step. Find it in the
[Zero Trust dashboard](https://one.dash.cloudflare.com/) → **Networks → Tunnels**, or from
the output of `cloudflared tunnel info`.

> Public hostname configuration happens after GitLab is installed — see [Step 4](#step-4-configure-tunnel-hostnames).

### 3. DNS Records (Cloudflare)

Create these DNS records in your Cloudflare zone. Point them at the tunnel (CNAME records are
automatically created when you add public hostnames in the Zero Trust dashboard).

| Record                        | Type  | Value                          | Proxy   |
| ----------------------------- | ----- | ------------------------------ | ------- |
| `gitlab.example.com`          | CNAME | `<tunnel-id>.cfargotunnel.com` | Proxied |
| `registry.gitlab.example.com` | CNAME | `<tunnel-id>.cfargotunnel.com` | Proxied |
| `ssh.gitlab.example.com`      | CNAME | `<tunnel-id>.cfargotunnel.com` | Proxied |
| `pages.example.com`           | CNAME | `<tunnel-id>.cfargotunnel.com` | Proxied |
| `*.pages.example.com`         | CNAME | `<tunnel-id>.cfargotunnel.com` | Proxied |
| `cdn.gitlab.example.com`      | CNAME | Worker route (if using CDN)    | Proxied |

> The CDN record is created automatically when you deploy the CDN Worker — the route is
> set by `generate-wrangler.sh` from `CDN_DOMAIN` in `.env`, not manually in the DNS dashboard.

### 4. Cloudflare API Token

Create an API token at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens).

You can use a single token with all permissions, or separate tokens for least-privilege:

- **Zone → DNS → Edit** — required. Used by Certbot on the LXC for DNS-01 challenges.
  This is the only permission sent to the LXC (via `cloudflare.ini`).
- **Zone → WAF → Edit** — optional. Used locally by `waf-rules.sh`.
- **Zone → Cache Rules → Edit** — optional. Used locally by `cache-rules.sh`.

> All scripts that call the Cloudflare API (`validate.sh`, `waf-rules.sh`, `cache-rules.sh`,
> `ratelimit-rules.sh`) run **locally** and require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` +
> `CLOUDFLARE_ACCOUNT_ID` in your shell environment (Global API key). These are NOT in `.env`.
> The LXC only receives a Certbot-scoped `CF_API_TOKEN` — it never has WAF, cache, or R2 permissions.

Also note your **Zone ID** from the zone's Overview page (right sidebar).

### 5. Cloudflare Access OIDC Application

In [Cloudflare One → Access controls → Applications](https://one.dash.cloudflare.com/):

1. Create a **Self-hosted** application
2. Set the **Application domain** to `gitlab.example.com`
3. Under **Settings → Authentication**, note the:
   - **Issuer URL** — `https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<app-id>`
   - **Client ID**
   - **Client Secret**
4. Add a **Policy** to control who can sign in (e.g. email domain, group membership)

### 6. GitHub OAuth Application (for imports)

At [github.com/settings/applications/new](https://github.com/settings/applications/new):

- **Application name:** GitLab Import
- **Homepage URL:** `https://gitlab.example.com`
- **Authorization callback URL:** `https://gitlab.example.com/users/auth/github/callback`

Note the **Client ID** and **Client Secret**.

### 7. Cloudflare R2 Buckets

GitLab uses a separate R2 bucket per object type (per [GitLab's recommendation](https://docs.gitlab.com/ee/administration/object_storage.html)).
The bucket names are derived from `R2_BUCKET_PREFIX` in `.env`.

In [dash.cloudflare.com → R2](https://dash.cloudflare.com/):

1. Create an **API token** under **R2 → Manage R2 API Tokens** with **Object Read & Write**
2. Note the:
   - **S3 endpoint** — `https://<account-id>.r2.cloudflarestorage.com`
   - **Access Key ID**
   - **Secret Access Key**
3. Create 10 buckets (replace `gitlab` with your chosen `R2_BUCKET_PREFIX`):

   | Bucket                    | Stores                                   | Usage       |
   | ------------------------- | ---------------------------------------- | ----------- |
   | `gitlab-artifacts`        | CI/CD job artifacts, test reports        | Core        |
   | `gitlab-lfs`              | Git LFS large files                      | Core        |
   | `gitlab-uploads`          | Issue attachments, avatars, image pastes | Core        |
   | `gitlab-packages`         | Package registry (npm, Docker, Maven)    | If needed   |
   | `gitlab-pages`            | GitLab Pages static site deployments     | If needed   |
   | `gitlab-external-diffs`   | MR diff offload from DB                  | Recommended |
   | `gitlab-terraform-state`  | Terraform state backend                  | If needed   |
   | `gitlab-dependency-proxy` | Docker Hub image cache                   | If needed   |
   | `gitlab-ci-secure-files`  | CI/CD secure files (signing certs, etc.) | If needed   |
   | `gitlab-backups`          | Daily backup archives (DB + repos)       | Recommended |

   > All 10 buckets are configured in `gitlab.rb`. Empty buckets cost nothing on R2, so create
   > them all upfront to avoid feature failures later.

   **Why R2?** Without object storage, all of the above would live on the LXC's local disk and
   grow unboundedly — CI artifacts pile up, LFS objects accumulate, registry layers stack. R2
   offloads all of this to durable, S3-compatible cloud storage so the LXC disk only needs to
   hold Git repositories (Gitaly), PostgreSQL, GitLab binaries, and logs. This is what keeps
   the LXC's disk requirements manageable at 50 GB. R2 also has no egress fees, so
   `proxy_download` (GitLab proxies object downloads through itself) costs nothing extra.
   When paired with the [CDN Worker](#gitlab-cdn), R2 objects served through GitLab are
   cached at Cloudflare's edge — so repeat downloads of the same file hit neither
   GitLab nor R2.

   **What stays on local disk regardless of R2:**

   | What                  | Size     | Why it can't be on R2                                 |
   | --------------------- | -------- | ----------------------------------------------------- |
   | Git bare repositories | Grows    | Gitaly requires local/NFS access                      |
   | PostgreSQL database   | ~75 MB+  | Relational DB (issues, MRs, users, pipeline metadata) |
   | GitLab binaries       | ~2.4 GB  | `/opt/gitlab` — the installed package                 |
   | Prometheus metrics    | ~200 MB+ | Time-series data, grows over time                     |
   | Docker image cache    | Varies   | Runner CI job images — managed by weekly Docker prune |
   | Logs                  | ~50 MB+  | Managed by logrotate                                  |

   Create them in one shot with the Wrangler CLI:

   ```bash
   for suffix in artifacts external-diffs lfs uploads packages dependency-proxy terraform-state pages ci-secure-files backups; do
     npx wrangler r2 bucket create "gitlab-${suffix}"
   done
   ```

---

## Files

| File                   | Description                                                                                                   |
| ---------------------- | ------------------------------------------------------------------------------------------------------------- |
| `validate.sh`          | Local — read-only validation of .env, SSH, Cloudflare API/DNS/R2, OIDC, HTTPS tunnel health                   |
| `deploy.sh`            | Local orchestrator — validates `.env`, pushes secrets + scripts to LXC, executes `setup.sh`                   |
| `setup.sh`             | Server-side — installs GitLab CE, configures TLS, UFW, nginx, OmniAuth, registry, pages, R2, daily backups    |
| `motd.sh`              | Sets `/etc/motd` using `banner.txt` + variables (called by `setup.sh`, or standalone)                         |
| `gitlabrunner.sh`      | Server-side — installs GitLab Runner, creates token via Rails, registers, starts                              |
| `runner-apps.sh`       | Server-side — installs runner CI tools from `runner-apps.json` (Docker, Node, npm, etc.)                      |
| `runner-apps.json`     | Manifest of tools and packages to install on the runner (apt, Docker, Node, npm global)                       |
| `gitlab-cdn/`          | CDN Worker — caching proxy for raw files and archives via VPC tunnel (see [its README](gitlab-cdn/README.md)) |
| `generate-wrangler.sh` | Inside `gitlab-cdn/` — generates `wrangler.jsonc` from `.env` values (`--dry-run` supported)                  |
| `waf-rules.sh`         | Provisions CDN WAF rules on Cloudflare via API                                                                |
| `cache-rules.sh`       | Provisions CDN cache rules on Cloudflare via API (read-merge-write, preserves non-CDN rules)                  |
| `ratelimit-rules.sh`   | Optional — rate limits `/-/health`, `/-/liveness`, `/-/readiness` via Cloudflare API                          |
| `ssh-config.sh`        | Local — configures `~/.ssh/config` + `known_hosts` for Git and admin SSH via Cloudflare Tunnel                |
| `ssonly.sh`            | Server-side — disables signup + password login, SSO-only (run after verifying SSO works)                      |
| `cloudflare-timing.sh` | Server-side — installs chrony and configures Cloudflare NTS as the time source                                |
| `chrony.conf`          | Chrony config using `time.cloudflare.com` with NTS authentication                                             |
| `banner.txt`           | ASCII art banner for the MOTD                                                                                 |
| `snippets/`            | Reference files — Rails console cheatsheet, standard `.gitignore` template                                    |
| `.env`                 | All config (secrets + non-sensitive) — **gitignored, never committed**                                        |
| `.env.example`         | Template with all required variables and descriptions                                                         |

---

## Environment Variables

Copy `.env.example` to `.env` and fill in real values. All variables are required unless noted.

| Variable                        | Description                                                                                                |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Target**                      |                                                                                                            |
| `LXC_HOST`                      | SSH target (e.g. `root@<LXC_IP>`)                                                                          |
| **GitLab Core**                 |                                                                                                            |
| `GITLAB_DOMAIN`                 | Primary domain (e.g. `gitlab.example.com`)                                                                 |
| `GITLAB_ROOT_EMAIL`             | Root user email                                                                                            |
| `GITLAB_ROOT_PASSWORD`          | Root user password (min 12 chars — auto-generated if too weak)                                             |
| `ORG_NAME`                      | Organization name (used in MOTD)                                                                           |
| `ORG_URL`                       | Organization URL (used in MOTD)                                                                            |
| **TLS / Cloudflare**            |                                                                                                            |
| `CF_API_TOKEN`                  | Cloudflare API token (Zone DNS Edit — used by Certbot on the LXC only)                                     |
| `CF_ZONE_ID`                    | _(optional)_ Cloudflare zone ID — only needed for `waf-rules.sh` / `cache-rules.sh`                        |
| `CERT_EMAIL`                    | Email for Let's Encrypt certificate notifications                                                          |
| **CDN**                         |                                                                                                            |
| `CDN_DOMAIN`                    | _(optional)_ CDN Worker hostname — needed for `waf-rules.sh`, `cache-rules.sh`, and `generate-wrangler.sh` |
| `CDN_WORKER_NAME`               | _(optional)_ Worker name (default: `cdn-gitlab`) — used by `generate-wrangler.sh`                          |
| `VPC_SERVICE_ID`                | _(optional)_ VPC Service ID from Zero Trust dashboard — used by `generate-wrangler.sh`                     |
| **Subdomains**                  |                                                                                                            |
| `REGISTRY_DOMAIN`               | Container Registry subdomain (e.g. `registry.gitlab.example.com`)                                          |
| `PAGES_DOMAIN`                  | GitLab Pages subdomain — wildcard cert auto-included (e.g. `pages.example.com`)                            |
| **Networking**                  |                                                                                                            |
| `INTERNAL_DNS`                  | LAN DNS resolver IP (for nginx OCSP stapling)                                                              |
| `SSH_ALLOW_CIDR`                | CIDR for UFW SSH access (e.g. `10.0.0.0/8`)                                                                |
| **System**                      |                                                                                                            |
| `TIMEZONE`                      | IANA timezone (e.g. `America/New_York`) — used by `cloudflare-timing.sh`                                   |
| **OmniAuth: Cloudflare Access** |                                                                                                            |
| `OIDC_ISSUER`                   | OIDC issuer URL from Cloudflare Access application                                                         |
| `OIDC_CLIENT_ID`                | Application (client) ID                                                                                    |
| `OIDC_CLIENT_SECRET`            | Application secret                                                                                         |
| **OmniAuth: GitHub**            |                                                                                                            |
| `GITHUB_APP_ID`                 | GitHub OAuth App client ID                                                                                 |
| `GITHUB_APP_SECRET`             | GitHub OAuth App client secret                                                                             |
| **R2 Object Storage**           |                                                                                                            |
| `R2_ENDPOINT`                   | S3-compatible endpoint URL                                                                                 |
| `R2_ACCESS_KEY`                 | R2 access key ID                                                                                           |
| `R2_SECRET_KEY`                 | R2 secret access key                                                                                       |
| `R2_BUCKET_PREFIX`              | Bucket name prefix — creates `<prefix>-artifacts`, `<prefix>-lfs`, etc.                                    |
| `R2_BACKUP_BUCKET`              | Backup archive bucket name (default: `<R2_BUCKET_PREFIX>-backups`)                                         |
| **Runner**                      |                                                                                                            |
| `RUNNER_NAME`                   | GitLab Runner description (e.g. `my-runner`)                                                               |
| `RUNNER_TAGS`                   | Comma-separated tags (e.g. `self-hosted,linux,x64`)                                                        |

---

## Step-by-Step Guide

### Step 1: Clone and Configure

```bash
git clone https://github.com/FlarelyLegal/cf-gitlab.git
cd cf-gitlab
cp .env.example .env
# Edit .env with real values from the prerequisites above
```

### Step 2: Dry Run

Every script supports `--dry-run`. Use it to verify configuration before making changes.

```bash
./deploy.sh --dry-run
```

This will:

- Validate all `.env` variables are set
- Test SSH connectivity to the LXC
- Confirm all local files exist
- Print a summary of every variable (secrets redacted)

Example output:

```
── DRY RUN (no changes will be made) ──

✓ SSH connected
✓ All local files present (setup.sh, motd.sh, banner.txt, cloudflare-timing.sh, chrony.conf)

── Dry run summary ──
  Target:         root@<LXC_IP>
  Domain:         gitlab.example.com
  Registry:       registry.gitlab.example.com
  Pages:          pages.example.com
  Root email:     admin@example.com
  Cert email:     admin@example.com
  Org:            Example — https://example.com
  SSH allow:      10.0.0.0/8
  Internal DNS:   10.0.0.1
  CF API token:   abc12345...(redacted)
  OIDC issuer:    https://myteam.cloudflareaccess.com/...
  GitHub app:     Ov23li0000000000000E
   R2 buckets:     gitlab-{artifacts,lfs,uploads,...} (10 buckets)
  Runner:         my-runner (self-hosted,linux,x64)
  Password:       ********************

  Would deploy:
    /root/.secrets/gitlab.env
    /root/.secrets/cloudflare.ini
    /tmp/gitlab-setup.sh
    /tmp/gitlab-motd.sh
    /tmp/gitlab-banner.txt
    /tmp/gitlab-timing.sh
    /tmp/gitlab-chrony.conf

✓ Dry run passed. Run without --dry-run to deploy.
```

### Step 3: Deploy GitLab

```bash
./deploy.sh
```

This pushes secrets and scripts to the LXC, then executes `setup.sh` remotely. Takes ~10–15 minutes
(most of the time is GitLab CE package installation and initial reconfigure).

> **Idempotency:** `deploy.sh` and `setup.sh` can be re-run safely. Certbot skips existing certs
> (`--keep-until-expiring`), `apt-get install` is a no-op if already installed, and UFW silently
> ignores duplicate rules. Note that `/etc/gitlab/gitlab.rb` will be overwritten on each run.

**What happens on the LXC (`setup.sh`):**

1. Sets MOTD via `motd.sh`
2. Configures Cloudflare NTS time sync (chrony)
3. Installs packages (ufw, curl, certbot) + enables UFW (default deny, 80, 443, SSH from `SSH_ALLOW_CIDR`)
4. Obtains TLS certs via Certbot + Cloudflare DNS-01 for all 3 domains (+wildcard for pages)
5. Adds GitLab CE APT repository
6. Pre-seeds `/etc/gitlab/gitlab.rb` with full config (nginx, OmniAuth, registry, pages, R2)
7. Installs GitLab CE (with password validation + auto-generation fallback)
8. Verifies root user exists (seeds database only if missing)
9. Installs certbot renewal hook (`gitlab-ctl hup nginx` on cert renewal)
10. Installs weekly registry GC cron (Sunday 3am)
11. Installs daily backup cron (2am — DB + repos to R2, config to local archive)

### Step 4: Configure Tunnel Hostnames

Now that GitLab is installed and running, add public hostnames to your tunnel in the
[Zero Trust dashboard](https://one.dash.cloudflare.com/) → **Networks → Tunnels → your tunnel → Public Hostname**.

| Hostname                      | Service              | Settings                                                           |
| ----------------------------- | -------------------- | ------------------------------------------------------------------ |
| `gitlab.example.com`          | `https://127.0.0.1`  | HTTP Host Header: `gitlab.example.com`, No TLS Verify: ON          |
| `registry.gitlab.example.com` | `https://127.0.0.1`  | HTTP Host Header: `registry.gitlab.example.com`, No TLS Verify: ON |
| `pages.example.com`           | `https://127.0.0.1`  | HTTP Host Header: `pages.example.com`, No TLS Verify: ON           |
| `ssh.gitlab.example.com`      | `ssh://127.0.0.1:22` | Disable Chunked Encoding: ON                                       |

> **No TLS Verify** is required because the tunnel terminates at `127.0.0.1` where nginx serves
> the certbot-issued certificate. The tunnel itself is encrypted end-to-end (QUIC).

> **SSH must be on a separate subdomain** (`ssh.gitlab.example.com`). Two entries on the same
> hostname conflict because the first wildcard path match catches all traffic.

### Step 5: Configure SSH Access

Set up client-side SSH through the tunnel for Git operations and admin access:

```bash
# Preview what will be added
./ssh-config.sh --dry-run

# Configure ~/.ssh/config + known_hosts
./ssh-config.sh
```

This adds two entries to `~/.ssh/config`:

- **`Host gitlab.example.com`** — Git access (`git clone git@gitlab.example.com:...`)
- **`Host gitlab-lxc`** — Admin root SSH (`ssh gitlab-lxc`)

Both use `cloudflared access ssh` as a ProxyCommand to route through the tunnel.
The script also scans the server's host key from the LXC IP and adds it under the
tunnel hostname so SSH doesn't prompt on first connect.

> Requires `cloudflared` installed locally (macOS: `brew install cloudflare/cloudflare/cloudflared`).

- **On LAN:** `ssh gitlab-lxc` routes through the tunnel (Zero Trust auth)
- **Off LAN:** Same — `cloudflared` proxies through the tunnel to sshd
- **Direct LAN:** `ssh root@<LXC_IP>` still works with traditional SSH keys

### Step 6: Validate Environment

Run the validation script to confirm the full deployment is healthy. This is read-only — it
does not make any changes.

```bash
./validate.sh
```

Checks performed:

1. `.env` exists, all required variables set, no placeholder values
2. SSH connectivity to the LXC
3. All local script files present
4. Cloudflare API credentials valid, zone accessible
5. DNS records exist for all domains (with proxy status — warns if DNS-only)
6. All 10 R2 buckets exist
7. OIDC issuer endpoint responds
8. GitLab health endpoint reachable via HTTPS (tunnel check)

> All Cloudflare API scripts require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` +
> `CLOUDFLARE_ACCOUNT_ID` in your shell environment (Global API key — set in your shell profile,
> not in `.env`).

### Step 7: Verify

Open `https://gitlab.example.com` in a browser. You should see the GitLab login page.

```bash
# SSH into the LXC and confirm services are healthy
ssh root@<LXC_IP>

gitlab-ctl status                   # all services should show "run"
gitlab-rake gitlab:check             # comprehensive health check
curl -skI https://localhost | head -5   # should return 200 or 302
```

**Verify TLS certificates:**

```bash
certbot certificates
# Should show 3 certs: GITLAB_DOMAIN, REGISTRY_DOMAIN, PAGES_DOMAIN (with wildcard)
```

**Verify UFW:**

```bash
ufw status
# Should show: 22/tcp ALLOW from <SSH_ALLOW_CIDR>, 80/tcp ALLOW, 443/tcp ALLOW
```

**Verify OmniAuth:** Click "Sign in with Cloudflare Access" on the login page. If you also need
local password login, sign in as `root` with the password from `.env` (or the auto-generated one
printed during setup).

> **Note:** No SMTP is configured. Password resets and email verification must be done via the
> Rails console: `gitlab-rails console`

### Step 8: Lock Down to SSO-Only (optional)

Once you've verified SSO login works in Step 7, you can lock down to SSO-only. This
disables manual signup and password login, and enables auto sign-in so users skip the login page
entirely and go straight through the Cloudflare Access OIDC flow.

> **Do not run this until you've confirmed SSO works.** If you lock yourself out, you'll need
> Rails console access on the LXC to re-enable password login (see emergency access below).

```bash
# Copy to LXC and dry-run first
scp ssonly.sh root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/ssonly.sh --dry-run'

# Apply
ssh root@<LXC_IP> 'bash /tmp/ssonly.sh'
```

**What changes:**

- **Signup:** disabled — no "Register" tab on the login page
- **Password login:** disabled — no username/password fields
- **Auto sign-in:** enabled — visitors are redirected straight to Cloudflare Access OIDC
  (no login page, no "click to sign in"). Since Access already has a session, login is instant.

Signup and password settings are application-level (stored in the database). Auto sign-in is a
`gitlab.rb` setting (the script runs `gitlab-ctl reconfigure` automatically). All persist across
upgrades.

**To revert** (re-enable signup + password login + remove auto sign-in):

```bash
ssh root@<LXC_IP> 'bash /tmp/ssonly.sh --revert'
```

**Bypass auto sign-in** (to reach the manual login page):

```
https://gitlab.example.com/users/sign_in?auto_sign_in=false
```

**Emergency root access** (if SSO breaks and you need to re-enable password login):

```bash
ssh root@<LXC_IP>
gitlab-rails runner "Gitlab::CurrentSettings.current_application_settings.update!(password_authentication_enabled_for_web: true)"
# Then remove auto sign-in so the login page appears:
sed -i '/omniauth_auto_sign_in_with_provider/d' /etc/gitlab/gitlab.rb
gitlab-ctl reconfigure
```

### Step 9: Install GitLab Runner (optional)

The runner script is not run by `deploy.sh` — it's a separate step. The secrets file
(`/root/.secrets/gitlab.env`) must already exist on the LXC from Step 3.

```bash
# Dry run first
scp gitlabrunner.sh root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/gitlabrunner.sh --dry-run'

# Then for real
ssh root@<LXC_IP> 'bash /tmp/gitlabrunner.sh'
```

**What happens:**

1. Adds GitLab Runner APT repository
2. Installs `gitlab-runner` + `gitlab-runner-helper-images`
3. Creates runner authentication token via `gitlab-rails runner` (~45s)
4. Registers the runner (shell executor, name + tags from `.env`)
5. Starts the service and verifies it's alive
6. Cleans up temp files

**Verify:** Go to `https://gitlab.example.com/admin/runners` �� the runner should appear as online.

> **Deprecation note:** `gitlabrunner.sh` uses the legacy `Ci::Runner.create!` method via Rails
> console. GitLab 16.0 deprecated registration tokens in favor of the `glrt-` auth token flow
> (`POST /api/v4/user/runners`). GitLab 17.0 removed the old registration endpoint. The Rails
> console method still works but may be removed in GitLab 18+. The script is idempotent — re-running
> it skips creation if a runner with the same name already exists.

#### Install Runner CI Tools

After the runner is registered, install the tools CI jobs need (Docker, Node.js, linters, etc.).
The tool list is defined in `runner-apps.json` — edit it to match your project requirements.

```bash
# Copy manifest + script to LXC
scp runner-apps.json runner-apps.sh root@<LXC_IP>:/tmp/

# Dry run first
ssh root@<LXC_IP> 'bash /tmp/runner-apps.sh --dry-run'

# Install
ssh root@<LXC_IP> 'bash /tmp/runner-apps.sh'
```

**What gets installed:**

| Category   | Packages                                                                |
| ---------- | ----------------------------------------------------------------------- |
| APT        | build-essential, curl, jq, shellcheck, python3, rsync, etc.             |
| Docker     | docker-ce, buildx, compose plugin (gitlab-runner added to docker group) |
| Node.js    | Node 22 LTS via NodeSource                                              |
| npm global | pnpm, wrangler, prettier, eslint, markdownlint-cli, etc.                |

The script is idempotent — already-installed packages are skipped.

A **weekly Docker prune cron** (Sunday 4am) is also installed — it removes Docker images
unused for 7+ days and stopped containers. This prevents CI job images (CodeClimate,
build images, etc.) from filling the LXC disk while keeping recently-used images cached
for faster pipeline runs.

### Step 10: Deploy CDN Worker + Rules (optional)

The CDN Worker caches public raw file and archive downloads at Cloudflare's edge, offloading
bandwidth from the GitLab instance. It connects to the private origin via a
[Workers VPC Service Binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/)
through the same `cloudflared` tunnel from Step 4 — the origin is never exposed publicly.

```
User → cdn.gitlab.example.com → Cloudflare Edge (cached)
         ↓ (cache miss)
       CDN Worker → VPC Service Binding → cloudflared tunnel → GitLab nginx
                                                                  ↓ (proxy_download)
                                                                 R2
```

**10a. Deploy the CDN Worker:**

Ensure `CDN_DOMAIN`, `VPC_SERVICE_ID`, and optionally `CDN_WORKER_NAME` are set in `.env`.

```bash
cd gitlab-cdn/
npm install
./generate-wrangler.sh                   # generates wrangler.jsonc from ../.env
npm run deploy
npx wrangler secret put STORAGE_TOKEN    # shared auth token
```

**10b. Enable in GitLab:**

Admin → Settings → Repository → **Static Objects External Storage**:

- **URL:** `https://cdn.gitlab.example.com`
- **Token:** same value as `STORAGE_TOKEN`

**10c. Provision WAF + cache rules:**

Requires `CF_ZONE_ID`, `CDN_DOMAIN`, and `VPC_SERVICE_ID` in `.env`.

```bash
# Preview first
./waf-rules.sh --dry-run
./cache-rules.sh --dry-run

# Then provision
./waf-rules.sh
./cache-rules.sh
```

> See [`gitlab-cdn/README.md`](gitlab-cdn/README.md) for full CDN Worker documentation,
> architecture details, and development instructions.

---

## Script Details

### `validate.sh`

Runs locally. Read-only check of the full deployment environment:

1. `.env` exists, all 24 required variables set, no `<placeholder>` values
2. SSH connectivity to the LXC (with OS version detection)
3. All local script files present
4. Cloudflare API credentials valid (Global API key), zone accessible
5. DNS records exist for all domains — reports record type and proxy status (warns if DNS-only on tunnel CNAMEs)
6. All 10 R2 buckets exist (requires `CLOUDFLARE_ACCOUNT_ID` in shell or parseable from `R2_ENDPOINT`)
7. OIDC issuer `.well-known/openid-configuration` responds
8. GitLab health endpoint reachable via HTTPS (tunnel check)

### `deploy.sh`

Runs locally. Reads `.env`, validates all variables, tests SSH, then:

1. Creates `/root/.secrets/` on the LXC (mode 700)
2. Writes `gitlab.env` (deployment variables) and `cloudflare.ini` (API token) to secrets dir
3. SCPs `setup.sh`, `motd.sh`, `banner.txt`, `cloudflare-timing.sh`, `chrony.conf` to `/tmp/` on the LXC
4. Executes `setup.sh` remotely via SSH

### `ssh-config.sh`

Runs locally. Configures `~/.ssh/config` and `~/.ssh/known_hosts` for accessing GitLab
through the Cloudflare Tunnel using client-side `cloudflared`:

1. Adds **git access** entry (`Host <GITLAB_DOMAIN>`) — for `git clone`/`push`/`pull` via tunnel
2. Adds **admin access** entry (`Host gitlab-lxc`) — for interactive root SSH via tunnel
3. Scans the server host key from the LXC IP and adds it under the tunnel hostname

All operations are idempotent — existing entries are skipped. Requires `cloudflared` installed
locally and `GITLAB_DOMAIN` + `LXC_HOST` in `.env`.

### `waf-rules.sh`

Runs locally. Provisions 2 CDN-scoped WAF rules via Cloudflare API:

| #   | Action | Description                                                            |
| --- | ------ | ---------------------------------------------------------------------- |
| 1   | skip   | Allow CDN Worker traffic (GET/HEAD/OPTIONS + `/raw/` or `/-/archive/`) |
| 2   | block  | Block all other CDN traffic                                            |

> Uses **read-merge-write** — preserves non-CDN WAF rules (bots, OCONUS challenges, etc.) in the
> same phase. Only rules whose expression references `CDN_DOMAIN` are replaced.

### `cache-rules.sh`

Runs locally. Provisions 2 CDN cache rules via Cloudflare API:

| #   | Action | Description                                            |
| --- | ------ | ------------------------------------------------------ |
| 1   | cache  | Public static objects — browser TTL: 1h, edge TTL: 24h |
| 2   | bypass | Authenticated requests (`?token=` in query string)     |

Uses **read-merge-write** to preserve non-CDN cache rules in the same phase (e.g. Media Bypass).

Both CDN scripts require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` in your shell environment
(Global API key).

### `ratelimit-rules.sh`

Runs locally. **Optional** — provisions a rate limit rule for the GitLab health endpoints via
Cloudflare API:

| Path           | Limit         | Action                       |
| -------------- | ------------- | ---------------------------- |
| `/-/health`    | 20 req/60s    | Block for 60s when exceeded  |
| `/-/liveness`  | per IP + colo | (same rule covers all three) |
| `/-/readiness` |               |                              |

```bash
./ratelimit-rules.sh --dry-run   # preview
./ratelimit-rules.sh             # provision
```

The health endpoints are already protected by Cloudflare's default DDoS mitigation and the tunnel
(no direct origin exposure). This rule is belt-and-suspenders — it prevents sustained abuse of
the health endpoints without affecting normal monitoring (even checking every 3 seconds stays
well under the limit).

Uses **read-merge-write** to preserve non-health rate limit rules in the same phase.

> Health endpoints require `gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0', '::/0']` in
> `gitlab.rb` (configured by `setup.sh`) to allow checks from any source IP through the tunnel.
> Without this, GitLab rejects health checks when `X-Forwarded-For` contains a non-local IP.

### `gitlab-cdn/`

Cloudflare Worker that caches public GitLab static objects at the edge. Deployed separately
via `wrangler deploy` (not part of `deploy.sh`). Run `generate-wrangler.sh` first to create
`wrangler.jsonc` from `.env` values. See [`gitlab-cdn/README.md`](gitlab-cdn/README.md)
for full documentation.

**Key design decisions:**

- **VPC Service Binding** — the Worker reaches the private GitLab origin through Cloudflare's
  private network (via the same `cloudflared` tunnel). The origin is never exposed publicly.
  HTTP is used inside the tunnel (QUIC encrypts end-to-end).
- **Indirect R2 access** — the Worker does not read from R2 directly. It fetches from GitLab
  (which has `proxy_download = true`), and GitLab fetches from R2 via the S3 API. The Worker
  caches the final response at the edge, so subsequent requests skip both GitLab and R2.
- **Query normalization** — irrelevant query parameters are stripped before caching, so
  `?inline=false&tracking=123` and `?inline=false` share the same cache entry.
- **Auth separation** — requests with `?token=` (private/authenticated content) are proxied
  but never cached. Public content (no token) is cached for 24h at the edge, 1h in the browser.
- **Analytics Engine** — every request logs cache status, latency, content size, and path type
  to a `gitlab_cdn` Analytics Engine dataset for monitoring.

---

## Backups

A daily cron job (`/usr/local/bin/gitlab-backup-all`, installed by `setup.sh`) runs at 2am and:

1. **Creates a GitLab backup** (`gitlab-backup create`) — dumps the PostgreSQL database and
   Git repositories into a `.tar` archive
2. **Uploads the archive to R2** — via `backup_upload_connection` to the `R2_BACKUP_BUCKET`
3. **Archives config files** — tars `/etc/gitlab/gitlab-secrets.json` and `/etc/gitlab/gitlab.rb`
   to `/var/opt/gitlab/backups/` as a separate `_config_backup.tar.gz`

Local backup archives are pruned after 7 days (`backup_keep_time`). R2 copies persist until
you delete them or set up a lifecycle rule.

### What's in the backup vs. what's already in R2

| Data                                    | Where it lives       | In backup?                        |
| --------------------------------------- | -------------------- | --------------------------------- |
| PostgreSQL database                     | Local disk           | Yes — dumped and uploaded to R2   |
| Git repositories                        | Local disk           | Yes — bundled and uploaded to R2  |
| Artifacts, LFS, uploads, packages, etc. | R2 (9 buckets)       | **No** — already durable in R2    |
| `gitlab-secrets.json` + `gitlab.rb`     | Local `/etc/gitlab/` | Yes — config archive (local only) |

> `gitlab-backup create` explicitly skips object types stored in object storage. The backup
> archive only contains the database and Git repos (~80MB for a small instance). R2 objects
> are protected by R2's own 11-nines durability — they don't need to be backed up again.

### Manual backup

```bash
# Run a backup manually (same as the cron job)
/usr/local/bin/gitlab-backup-all

# Or just the GitLab backup (no config archive)
gitlab-backup create

# List local backups
ls -lh /var/opt/gitlab/backups/

# List R2 backups (requires aws CLI or rclone configured for R2)
aws s3 ls s3://gitlab-backups/ --endpoint-url "${R2_ENDPOINT}"
```

### Restore from backup

```bash
# 1. Restore config files FIRST (encryption keys are critical)
tar -xzf /var/opt/gitlab/backups/<timestamp>_config_backup.tar.gz -C /

# 2. Reconfigure to apply restored config
gitlab-ctl reconfigure

# 3. Stop services that write to the database
gitlab-ctl stop puma
gitlab-ctl stop sidekiq

# 4. Restore the GitLab backup (DB + repos)
#    Download from R2 first if not on local disk:
#    aws s3 cp s3://gitlab-backups/<timestamp>_gitlab_backup.tar \
#        /var/opt/gitlab/backups/ --endpoint-url "${R2_ENDPOINT}"
gitlab-backup restore BACKUP=<timestamp>_gitlab_backup

# 5. Restart all services
gitlab-ctl start

# 6. Verify
gitlab-rake gitlab:check
```

> You **must** restore `/etc/gitlab/gitlab-secrets.json` before running `gitlab-ctl reconfigure`,
> or encrypted data (CI variables, 2FA secrets, runner tokens) will be unreadable.
>
> See [GitLab backup/restore docs](https://docs.gitlab.com/ee/administration/backup_restore/) for
> full details on restore procedures.

---

## Runner Hardening (Co-located)

The shell executor runs CI jobs as the `gitlab-runner` user on the same LXC as GitLab.
Fine for a small trusted team — lock it down to prevent scope creep.

### Filesystem Permissions

```bash
# GitLab data + config (verify these are root-only)
chmod 700 /etc/gitlab
chmod 700 /var/opt/gitlab
chmod 700 /var/opt/gitlab/postgresql

# Secrets and certificates
chmod 700 /root/.secrets
chmod 600 /root/.secrets/*
chmod 700 /etc/letsencrypt/live
chmod 700 /etc/letsencrypt/archive

# Temp files with tokens
chmod 600 /tmp/gitlab_pat 2>/dev/null || true
```

### No Sudo Access

```bash
# Verify gitlab-runner is NOT in sudo group
groups gitlab-runner
# → gitlab-runner

# Ensure no sudoers entry
grep gitlab-runner /etc/sudoers /etc/sudoers.d/* 2>/dev/null
# → (empty)
```

### Systemd Resource Limits

Cap the runner so CI jobs can't starve GitLab services:

```bash
systemctl edit gitlab-runner
```

```ini
[Service]
MemoryMax=4G
CPUQuota=400%
```

Limits to 4 GB RAM / 4 CPU cores — leaves the rest for Puma, Sidekiq, Gitaly, PostgreSQL.

### Network Isolation (optional)

Block the runner user from hitting internal services directly:

```bash
iptables -A OUTPUT -m owner --uid-owner gitlab-runner -p tcp --dport 5432 -j DROP
iptables -A OUTPUT -m owner --uid-owner gitlab-runner -p tcp --dport 6379 -j DROP
iptables -A OUTPUT -m owner --uid-owner gitlab-runner -p tcp --dport 8075 -j DROP
```

> These services use Unix sockets by default — this is defense-in-depth.
> Persist with `iptables-save` or add to a startup script.

### Already Safe by Default

- `gitlab-runner` has no root access, can't run `gitlab-ctl`
- Internal services (postgres, redis, gitaly) listen on Unix sockets owned by `git`
- Builds isolated to `/home/gitlab-runner/builds/`
- Can't modify GitLab config or access the database directly

### When to Move to a Separate Runner

- Untrusted contributors can submit CI jobs (MRs from forks)
- CI jobs need Docker (DinD works better on a dedicated host)
- Build workloads compete with GitLab for CPU/RAM
- You want full network isolation between CI and GitLab data

---

## External Self-Hosted Runner

For workloads that need Docker or full network isolation, use a dedicated runner LXC instead of
the co-located shell executor. This section is planned but not yet automated.

**Target:** Dedicated runner LXC with Docker executor, separate registration token, and
network-level isolation from the GitLab data plane. The LXC should have Docker, Node (fnm),
pnpm, and build-essential installed at minimum.

---

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
