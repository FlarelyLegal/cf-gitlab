# Self-Hosted GitLab with Cloudflare

[![Zero Trust](https://img.shields.io/badge/Zero%20Trust-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/)
[![Tunnel](https://img.shields.io/badge/Tunnel-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
[![Access](https://img.shields.io/badge/Access-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/policies/access/)
[![Workers](https://img.shields.io/badge/Workers-F38020?logo=cloudflareworkers&logoColor=white)](https://developers.cloudflare.com/workers/)
[![Workers VPC](https://img.shields.io/badge/Workers%20VPC-F38020?logo=cloudflareworkers&logoColor=white)](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/cloudflared/tunnel-virtual-networks/)
[![R2](https://img.shields.io/badge/R2-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/r2/)
[![WAF](https://img.shields.io/badge/WAF-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/waf/)
[![DNS](https://img.shields.io/badge/DNS-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/dns/)
[![NTS](https://img.shields.io/badge/NTS-F38020?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/time-services/)

[![GitLab CE](https://img.shields.io/badge/GitLab%20CE-FC6D26?logo=gitlab&logoColor=white)](https://about.gitlab.com/)
[![Debian 13](https://img.shields.io/badge/Debian%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![Shell](https://img.shields.io/badge/Shell-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%203.0-blue.svg)](LICENSE)

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/FlarelyLegal/cf-gitlab/main/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/FlarelyLegal/cf-gitlab.git
cd cf-gitlab
cp .env.example .env
```

---

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
`scripts/validate.sh` is read-only by design and does not need `--dry-run`.

---

## Prerequisites

Complete these **before** running any scripts.

### 1. Debian 13 LXC

Create a Proxmox LXC (or similar) with:

- **OS:** Debian 13 (Trixie)
- **Resources:** 8 CPU, 16 GB RAM, 50 GB disk (minimum)
- **Network:** Static IP on your LAN, DNS resolver configured
- **SSH:** Root login enabled, your public key in `/root/.ssh/authorized_keys`

> If you're on Proxmox, the [community scripts](https://community-scripts.github.io/ProxmoxVE/)
> project has a one-liner to create a Debian LXC:
>
> ```bash
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"
> ```

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
[Zero Trust dashboard](https://dash.cloudflare.com/one) → **Networks → Connectors → Cloudflare Tunnels**, or from
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
- **Zone → WAF → Edit** — optional. Used locally by `cloudflare/waf/waf-rules.sh`.
- **Zone → Cache Rules → Edit** — optional. Used locally by `cloudflare/waf/cache-rules.sh`.

> All scripts that call the Cloudflare API (`scripts/validate.sh`, `cloudflare/waf/waf-rules.sh`, `cloudflare/waf/cache-rules.sh`,
> `cloudflare/waf/ratelimit-rules.sh`) run **locally** and require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` +
> `CLOUDFLARE_ACCOUNT_ID` in your shell environment (Global API key). These are NOT in `.env`.
> The LXC only receives a Certbot-scoped `CF_API_TOKEN` — it never has WAF, cache, or R2 permissions.

**Tip (macOS):** Store your Cloudflare credentials in Keychain and reference them from `~/.zshrc`
so they are never written to disk in plain text:

```bash
# Add to Keychain (one time)
security add-generic-password -s "Cloudflare API Key" -a "$USER" -w "your-global-api-key" -U
security add-generic-password -s "Cloudflare Email" -a "$USER" -w "you@example.com" -U
security add-generic-password -s "Cloudflare Account ID" -a "My Account" -w "your-account-id" -U
```

```bash
# Add to ~/.zshrc
export CLOUDFLARE_API_KEY=$(security find-generic-password -s "Cloudflare API Key" -w 2>/dev/null)
export CLOUDFLARE_EMAIL=$(security find-generic-password -s "Cloudflare Email" -w 2>/dev/null)
export CLOUDFLARE_ACCOUNT_ID=$(security find-generic-password -s "Cloudflare Account ID" -a "My Account" -w 2>/dev/null)
```

Reload your terminal (`source ~/.zshrc` or open a new tab) after adding the exports.

Also note your **Zone ID** from the zone's Overview page (right sidebar).

### 5. Cloudflare Access OIDC Application

You need **two** Access applications: one to protect the domain, and one to act as the OIDC
identity provider for GitLab's OmniAuth.

In [Cloudflare One](https://dash.cloudflare.com/one) → **Access controls** → **Applications**:

**5a. Self-hosted application** (protects the domain):

1. Select **Add an application** → **Self-hosted**
2. Set the **Application domain** to `gitlab.example.com`
3. Add a **Policy** to control who can reach the site (e.g. email domain, group membership)
4. Select **Save application**

**5b. SaaS application** (OIDC provider for GitLab OmniAuth):

1. Select **Add an application** → **SaaS**
2. In **Application**, enter a name (e.g. `GitLab OIDC`)
3. For the authentication protocol, select **OIDC**, then select **Add application**
4. In **Scopes**, ensure `openid`, `email`, and `profile` are selected
5. In **Redirect URLs**, enter `https://gitlab.example.com/users/auth/openid_connect/callback`
6. Copy the following values (you will need them for `.env`):
   - **Client ID** → `OIDC_CLIENT_ID`
   - **Client Secret** → `OIDC_CLIENT_SECRET`
   - **Issuer** → `OIDC_ISSUER` (format: `https://<team>.cloudflareaccess.com/cdn-cgi/access/sso/oidc/<client-id>`)
7. Add a **Policy** with the same rules as the self-hosted app
8. Select **Save application**

> The self-hosted app gates who can reach GitLab at all. The SaaS app provides the OIDC
> endpoints that GitLab calls during the OmniAuth login flow. Both are required.
>
> See [Generic OIDC application](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/saas-apps/generic-oidc-saas/)
> in the Cloudflare docs for detailed OIDC SaaS setup instructions.

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
   When paired with the [CDN Worker](gitlab-cdn/README.md), R2 objects served through GitLab are
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
     CLOUDFLARE_ACCOUNT_ID="<YOUR_ACCOUNT_ID>" npx wrangler r2 bucket create "gitlab-${suffix}"
   done
   ```

---

## Environment Variables

Copy `.env.example` to `.env`. All variables are required unless marked optional.

### GitLab

| Variable               | Description                                           |
| ---------------------- | ----------------------------------------------------- |
| `LXC_HOST`             | SSH target (e.g. `root@10.0.0.50`)                    |
| `GITLAB_DOMAIN`        | Primary domain (e.g. `gitlab.example.com`)            |
| `GITLAB_ROOT_EMAIL`    | Admin user email                                      |
| `GITLAB_ROOT_PASSWORD` | Admin password (min 12 chars, auto-generated if weak) |
| `ORG_NAME`             | Organization name (MOTD)                              |
| `ORG_URL`              | Organization URL (MOTD)                               |
| `REGISTRY_DOMAIN`      | Container Registry subdomain                          |
| `PAGES_DOMAIN`         | GitLab Pages subdomain (wildcard cert auto-included)  |

### TLS and Networking

| Variable         | Description                                        |
| ---------------- | -------------------------------------------------- |
| `CF_API_TOKEN`   | Cloudflare API token (Zone DNS Edit, Certbot only) |
| `CERT_EMAIL`     | Let's Encrypt notification email                   |
| `INTERNAL_DNS`   | LAN DNS resolver IP (nginx OCSP stapling)          |
| `SSH_ALLOW_CIDR` | CIDR for UFW SSH access (e.g. `10.0.0.0/8`)        |
| `TIMEZONE`       | IANA timezone (e.g. `America/New_York`)            |

### OmniAuth

| Variable             | Description                              |
| -------------------- | ---------------------------------------- |
| `OIDC_ISSUER`        | Cloudflare Access issuer URL             |
| `OIDC_CLIENT_ID`     | Access SaaS application client ID        |
| `OIDC_CLIENT_SECRET` | Access SaaS application secret           |
| `GITHUB_APP_ID`      | GitHub OAuth App client ID (for imports) |
| `GITHUB_APP_SECRET`  | GitHub OAuth App client secret           |

### R2 Object Storage

| Variable           | Description                                                     |
| ------------------ | --------------------------------------------------------------- |
| `R2_ENDPOINT`      | S3-compatible endpoint URL                                      |
| `R2_ACCESS_KEY`    | Access key ID                                                   |
| `R2_SECRET_KEY`    | Secret access key                                               |
| `R2_BUCKET_PREFIX` | Bucket name prefix (creates `<prefix>-artifacts`, `-lfs`, etc.) |
| `R2_BACKUP_BUCKET` | Backup bucket name (default: `<R2_BUCKET_PREFIX>-backups`)      |

### CDN (optional)

| Variable          | Description                                     |
| ----------------- | ----------------------------------------------- |
| `CF_ZONE_ID`      | Cloudflare zone ID (for WAF/cache rule scripts) |
| `CDN_DOMAIN`      | CDN Worker hostname                             |
| `CDN_WORKER_NAME` | Worker name (default: `cdn-gitlab`)             |
| `VPC_SERVICE_ID`  | VPC Service ID from Zero Trust dashboard        |

### Runner

| Variable      | Description                                         |
| ------------- | --------------------------------------------------- |
| `RUNNER_NAME` | Runner description (e.g. `my-runner`)               |
| `RUNNER_TAGS` | Comma-separated tags (e.g. `self-hosted,linux,x64`) |

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
scripts/deploy.sh --dry-run
```

This will:

- Validate all `.env` variables are set
- Test SSH connectivity to the LXC
- Confirm all local files exist
- Print a summary of every variable (secrets redacted)

Example output:

```text
── DRY RUN (no changes will be made) ──

✓ SSH connected
✓ All local files present

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
scripts/deploy.sh
```

This pushes secrets and scripts to the LXC, then executes `scripts/setup.sh` remotely. Takes ~10-15 minutes
(most of the time is GitLab CE package installation and initial reconfigure).

> **Tip:** The remote `scripts/setup.sh` execution is a long SSH session. If your connection is unstable,
> install `screen` on the LXC first, then run setup inside it so it survives disconnects:
>
> ```bash
> # Run scripts/deploy.sh steps 1-4 (push files) normally, then:
> ssh root@<LXC_IP> 'apt-get install -y screen'
> ssh root@<LXC_IP> 'screen -dmS gitlab-setup bash -c "/tmp/gitlab-setup.sh 2>&1 | tee /root/setup.log"'
> # Monitor progress:
> ssh root@<LXC_IP> 'tail -f /root/setup.log'
> ```

> **Idempotency:** `scripts/deploy.sh` and `scripts/setup.sh` can be re-run safely. Certbot skips existing certs
> (`--keep-until-expiring`), `apt-get install` is a no-op if already installed, and UFW silently
> ignores duplicate rules. Note that `/etc/gitlab/gitlab.rb` will be overwritten on each run.

**What happens on the LXC (`scripts/setup.sh`):**

1. Sets MOTD via `scripts/motd.sh`
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
[Zero Trust dashboard](https://dash.cloudflare.com/one) → **Networks → Connectors → Cloudflare Tunnels → your tunnel → Public Hostname**.

| Hostname                      | Service              | Settings                                                           |
| ----------------------------- | -------------------- | ------------------------------------------------------------------ |
| `gitlab.example.com`          | `https://127.0.0.1`  | HTTP Host Header: `gitlab.example.com`, No TLS Verify: ON          |
| `registry.gitlab.example.com` | `https://127.0.0.1`  | HTTP Host Header: `registry.gitlab.example.com`, No TLS Verify: ON |
| `pages.example.com`           | `https://127.0.0.1`  | HTTP Host Header: `pages.example.com`, No TLS Verify: ON           |
| `ssh.gitlab.example.com`      | `ssh://127.0.0.1:22` | (none required)                                                    |

> **No TLS Verify** is required because the tunnel terminates at `127.0.0.1` where nginx serves
> the certbot-issued certificate. The tunnel itself is encrypted end-to-end (QUIC).

> **SSH must be on a separate subdomain** (`ssh.gitlab.example.com`). Two entries on the same
> hostname conflict because the first wildcard path match catches all traffic.

### Step 5: Configure SSH Access

Set up client-side SSH through the tunnel for Git operations and admin access:

```bash
# Preview what will be added
scripts/ssh-config.sh --dry-run

# Configure ~/.ssh/config + known_hosts
scripts/ssh-config.sh
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
scripts/validate.sh
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

### Step 7b: Configure SMTP (optional)

Configure SMTP for notification emails, password resets, and email verifications.
See [`scripts/smtp.md`](scripts/smtp.md).

### Step 8: Lock Down to SSO-Only (optional)

Disable password login and enable auto sign-in through Cloudflare Access OIDC.
See [`scripts/sso-only.md`](scripts/sso-only.md).

### Step 9: Install GitLab Runner (optional)

Multiple runner deployment options are available. See [`runners/README.md`](runners/README.md)
for full details on each approach, configuration, and CI tool installation.

### Step 10: Deploy CDN Worker + Rules (optional)

Cache public raw file and archive downloads at Cloudflare's edge via a Workers VPC Service.
See [`gitlab-cdn/deploy.md`](gitlab-cdn/deploy.md) for deployment steps and
[`gitlab-cdn/README.md`](gitlab-cdn/README.md) for architecture details.

### Step 11: Install Hooks (optional)

Install server hooks (pre-receive) and file hooks for push policy enforcement and event
notifications. See [`optional/install.md`](optional/install.md) for installation steps and
[`optional/README.md`](optional/README.md) for what each hook does.

### Step 12: Web IDE Extension Host (optional)

Serve VS Code extension assets from your own instance instead of GitLab's CDN.
See [`scripts/webide.md`](scripts/webide.md).

---

## Script & Component Details

For detailed documentation on each script, see the README in each directory:

- [`scripts/README.md`](scripts/README.md) — deploy, validate, SSH config, SSO lockdown, Web IDE setup
- [`runners/README.md`](runners/README.md) — runner deployment (co-located, external, LXC container provisioning)
- [`stacks/README.md`](stacks/README.md) — Docker Compose stacks (Kroki, etc.)
- [`cloudflare/README.md`](cloudflare/README.md) — WAF, cache, and rate limit rule provisioning
- [`gitlab-cdn/README.md`](gitlab-cdn/README.md) — CDN Worker architecture, deployment, and development
- [`optional/README.md`](optional/README.md) — server hooks and file hooks

---

## Backups

A daily cron job (`/usr/local/bin/gitlab-backup-all`, installed by `scripts/setup.sh`) runs at 2am and:

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

## Issues

Open issues on [GitHub](https://github.com/FlarelyLegal/cf-gitlab/issues).
They are automatically mirrored to the self-hosted GitLab instance via a
[GitHub Actions workflow](.github/workflows/sync-issues.yml).

---

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
