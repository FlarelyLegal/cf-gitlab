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

Without SMTP, GitLab cannot send notification emails, password resets, or email verifications.
If you skip this step, those actions must be done via the Rails console.

Append the following to `/etc/gitlab/gitlab.rb` on the LXC (adjust values for your SMTP provider):

```ruby
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.example.com"
gitlab_rails['smtp_port'] = 587
gitlab_rails['smtp_user_name'] = "gitlab@example.com"
gitlab_rails['smtp_password'] = "<SMTP_PASSWORD>"
gitlab_rails['smtp_domain'] = "example.com"
gitlab_rails['smtp_authentication'] = "plain"
gitlab_rails['smtp_enable_starttls_auto'] = true

gitlab_rails['gitlab_email_from'] = "gitlab@example.com"
gitlab_rails['gitlab_email_reply_to'] = "gitlab@example.com"
gitlab_rails['gitlab_email_display_name'] = "GitLab"
```

Then reconfigure and send a test email:

```bash
gitlab-ctl reconfigure
gitlab-rails runner "Notify.test_email('you@example.com', 'GitLab SMTP Test', 'It works.').deliver_now"
```

> See [GitLab SMTP docs](https://docs.gitlab.com/omnibus/settings/smtp.html) for provider-specific
> examples (Gmail, SendGrid, Amazon SES, etc.).

### Step 8: Lock Down to SSO-Only (optional)

Once you've verified SSO login works in Step 7, you can lock down to SSO-only. This
disables manual signup and password login, and enables auto sign-in so users skip the login page
entirely and go straight through the Cloudflare Access OIDC flow.

> **Do not run this until you've confirmed SSO works.** If you lock yourself out, you'll need
> Rails console access on the LXC to re-enable password login (see emergency access below).

```bash
# Copy to LXC and dry-run first
scp scripts/sso-only.sh root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/sso-only.sh --dry-run'

# Apply
ssh root@<LXC_IP> 'bash /tmp/sso-only.sh'
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
ssh root@<LXC_IP> 'bash /tmp/sso-only.sh --revert'
```

**Bypass auto sign-in** (to reach the manual login page):

```text
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

The runner script is not run by `scripts/deploy.sh`, it's a separate step. The secrets file
(`/root/.secrets/gitlab.env`) must already exist on the LXC from Step 3.

```bash
# Dry run first
scp runners/gitlabrunner.sh root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/gitlabrunner.sh --dry-run'

# Then for real
ssh root@<LXC_IP> 'bash /tmp/gitlabrunner.sh'
```

> **Tip:** The runner script loads Rails (~45s) to create an auth token. If your SSH connection
> is flaky, run it inside `screen` as shown in [Step 3](#step-3-deploy-gitlab).

**What happens:**

1. Adds GitLab Runner APT repository
2. Installs `gitlab-runner` + `gitlab-runner-helper-images`
3. Creates runner authentication token via `gitlab-rails runner` (~45s)
4. Registers the runner (shell executor, name + tags from `.env`)
5. Starts the service and verifies it's alive
6. Cleans up temp files

**Verify:** Go to `https://gitlab.example.com/admin/runners`. The runner should appear as online.

> **Deprecation note:** `runners/gitlabrunner.sh` uses the legacy `Ci::Runner.create!` method via Rails
> console. GitLab 16.0 deprecated registration tokens in favor of the `glrt-` auth token flow
> (`POST /api/v4/user/runners`). GitLab 17.0 removed the old registration endpoint. The Rails
> console method still works but may be removed in GitLab 18+. The script is idempotent — re-running
> it skips creation if a runner with the same name already exists.

#### Install Runner CI Tools

After the runner is registered, install the tools CI jobs need (Docker, Node.js, linters, etc.).
The tool list is defined in `runners/runner-apps.json` — edit it to match your project requirements.

```bash
# Copy manifest + script to LXC
scp runners/runner-apps.json runners/runner-apps.sh root@<LXC_IP>:/tmp/

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
[Workers VPC Service](https://developers.cloudflare.com/workers-vpc/)
through the same `cloudflared` tunnel from Step 4, so the origin is never exposed publicly.

```text
User → cdn.gitlab.example.com → Cloudflare Edge (cached)
         ↓ (cache miss)
       CDN Worker → Workers VPC Service → cloudflared tunnel → GitLab nginx
                                                                   ↓ (proxy_download)
                                                                  R2
```

**10a. Deploy the CDN Worker:**

Ensure `CDN_DOMAIN`, `VPC_SERVICE_ID`, and optionally `CDN_WORKER_NAME` are set in `.env`.

First, generate a random shared auth token. The CDN Worker sends this token to GitLab when
fetching content through the tunnel, and GitLab verifies it before serving the response. Both
sides must use the same value.

```bash
# Generate a random token
openssl rand -base64 32
```

Save the output. You will need it twice: once for the Worker secret and once for GitLab admin.

```bash
cd gitlab-cdn/
npm install
./generate-wrangler.sh                   # generates wrangler.jsonc from ../.env
npm run deploy
npx wrangler secret put STORAGE_TOKEN    # paste the token you generated above
```

**10b. Enable in GitLab:**

Admin → Settings → Repository → **Static Objects External Storage**:

- **URL:** `https://cdn.gitlab.example.com`
- **Token:** paste the same token from step 10a

**10c. Provision WAF + cache rules:**

Requires `CF_ZONE_ID`, `CDN_DOMAIN`, and `VPC_SERVICE_ID` in `.env`.

```bash
# Preview first
./cloudflare/waf/waf-rules.sh --dry-run
./cloudflare/waf/cache-rules.sh --dry-run

# Then provision
./cloudflare/waf/waf-rules.sh
./cloudflare/waf/cache-rules.sh
```

> See [`gitlab-cdn/README.md`](gitlab-cdn/README.md) for full CDN Worker documentation,
> architecture details, and development instructions.

### Step 11: Install Hooks (optional)

Install server hooks (pre-receive) and file hooks for push policy enforcement and event
notifications. See [`optional/README.md`](optional/README.md) for full details.

**Server hooks** (synchronous, can reject pushes):

```bash
# On the GitLab LXC:
mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d
scp optional/enforce-branch-naming optional/block-file-extensions \
    optional/enforce-commit-message optional/detect-secrets \
    root@<LXC_IP>:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/
ssh root@<LXC_IP> 'chmod +x /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/* && \
    chown -R git:git /var/opt/gitlab/gitaly/custom_hooks'
```

> Requires `gitaly['configuration'] = { hooks: { custom_hooks_dir: '/var/opt/gitlab/gitaly/custom_hooks' } }`
> in `gitlab.rb` + `gitlab-ctl reconfigure`. Hooks are global (apply to all repos).

**File hooks** (asynchronous, cannot block actions):

```bash
scp optional/notify-admin.rb optional/discord-failed-login.rb \
    root@<LXC_IP>:/opt/gitlab/embedded/service/gitlab-rails/file_hooks/
ssh root@<LXC_IP> 'chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/*.rb'
```

Validate with `gitlab-rake file_hooks:validate` on the LXC.

---

## Script Details

### `scripts/validate.sh`

Runs locally. Read-only check of the full deployment environment:

1. `.env` exists, all 24 required variables set, no `<placeholder>` values
2. SSH connectivity to the LXC (with OS version detection)
3. All local script files present
4. Cloudflare API credentials valid (Global API key), zone accessible
5. DNS records exist for all domains — reports record type and proxy status (warns if DNS-only on tunnel CNAMEs)
6. All 10 R2 buckets exist (requires `CLOUDFLARE_ACCOUNT_ID` in shell or parseable from `R2_ENDPOINT`)
7. OIDC issuer `.well-known/openid-configuration` responds
8. GitLab health endpoint reachable via HTTPS (tunnel check)

### `scripts/deploy.sh`

Runs locally. Reads `.env`, validates all variables, tests SSH, then:

1. Creates `/root/.secrets/` on the LXC (mode 700)
2. Writes `gitlab.env` (deployment variables) and `cloudflare.ini` (API token) to secrets dir
3. SCPs `scripts/setup.sh`, `scripts/motd.sh`, `config/banner.txt`, `cloudflare/timing.sh`, `config/chrony.conf` to `/tmp/` on the LXC
4. Executes `scripts/setup.sh` remotely via SSH

### `scripts/ssh-config.sh`

Runs locally. Configures `~/.ssh/config` and `~/.ssh/known_hosts` for accessing GitLab
through the Cloudflare Tunnel using client-side `cloudflared`:

1. Adds **git access** entry (`Host <GITLAB_DOMAIN>`) — for `git clone`/`push`/`pull` via tunnel
2. Adds **admin access** entry (`Host gitlab-lxc`) — for interactive root SSH via tunnel
3. Scans the server host key from the LXC IP and adds it under the tunnel hostname

All operations are idempotent — existing entries are skipped. Requires `cloudflared` installed
locally and `GITLAB_DOMAIN` + `LXC_HOST` in `.env`.

### `runners/deploy-runner.sh`

Runs locally. Orchestrates deployment of an external GitLab Runner to a dedicated LXC:

1. Loads `.env` for `GITLAB_DOMAIN`, `ORG_NAME`, `ORG_URL`
2. Validates SSH connectivity and required local files
3. Pushes `runner.env` secrets to `/root/.secrets/` on the runner LXC
4. SCPs `external-runner.sh`, `runner-apps.sh`, `runner-apps.json`, and `banner.txt` to `/tmp/`
5. Launches `external-runner.sh` in a `screen` session (survives SSH disconnects)
6. Streams live output back to the terminal and reports the exit code

Requires `RUNNER_LXC_HOST` and `RUNNER_GITLAB_PAT` as environment variables.
See [External Self-Hosted Runner](#external-self-hosted-runner) for full usage.

### `runners/external-runner.sh`

Runs on the runner LXC (server-side). Installs and registers a GitLab Runner:

1. Sets MOTD with runner info
2. Configures UFW (default deny, SSH from `SSH_ALLOW_CIDR`)
3. Installs `gitlab-runner` + helper images from the GitLab APT repository
4. Creates a runner token via `POST /api/v4/user/runners` (new `glrt-` token flow)
5. Registers the runner with shell executor
6. Starts and verifies the runner service
7. Installs CI tools from `runner-apps.json` via `runner-apps.sh`

Reads config from `/root/.secrets/runner.env` (pushed by `deploy-runner.sh`). Idempotent:
skips runner creation if one with the same name already exists.

### `cloudflare/waf/waf-rules.sh`

Runs locally. Provisions 2 CDN-scoped WAF rules via Cloudflare API:

| #   | Action | Description                                                            |
| --- | ------ | ---------------------------------------------------------------------- |
| 1   | skip   | Allow CDN Worker traffic (GET/HEAD/OPTIONS + `/raw/` or `/-/archive/`) |
| 2   | block  | Block all other CDN traffic                                            |

> Uses **read-merge-write** — preserves non-CDN WAF rules (bots, OCONUS challenges, etc.) in the
> same phase. Only rules whose expression references `CDN_DOMAIN` are replaced.

### `cloudflare/waf/cache-rules.sh`

Runs locally. Provisions 2 CDN cache rules via Cloudflare API:

| #   | Action | Description                                            |
| --- | ------ | ------------------------------------------------------ |
| 1   | cache  | Public static objects — browser TTL: 1h, edge TTL: 24h |
| 2   | bypass | Authenticated requests (`?token=` in query string)     |

Uses **read-merge-write** to preserve non-CDN cache rules in the same phase (e.g. Media Bypass).

Both CDN scripts require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` in your shell environment
(Global API key).

### `cloudflare/waf/ratelimit-rules.sh`

Runs locally. **Optional** — provisions a rate limit rule for the GitLab health endpoints via
Cloudflare API:

| Path           | Limit         | Action                       |
| -------------- | ------------- | ---------------------------- |
| `/-/health`    | 20 req/60s    | Block for 60s when exceeded  |
| `/-/liveness`  | per IP + colo | (same rule covers all three) |
| `/-/readiness` |               |                              |

```bash
./cloudflare/waf/ratelimit-rules.sh --dry-run   # preview
./cloudflare/waf/ratelimit-rules.sh             # provision
```

The health endpoints are already protected by Cloudflare's default DDoS mitigation and the tunnel
(no direct origin exposure). This rule is belt-and-suspenders — it prevents sustained abuse of
the health endpoints without affecting normal monitoring (even checking every 3 seconds stays
well under the limit).

Uses **read-merge-write** to preserve non-health rate limit rules in the same phase.

> Health endpoints require `gitlab_rails['monitoring_whitelist'] = ['0.0.0.0/0', '::/0']` in
> `gitlab.rb` (configured by `scripts/setup.sh`) to allow checks from any source IP through the tunnel.
> Without this, GitLab rejects health checks when `X-Forwarded-For` contains a non-local IP.

### `gitlab-cdn/`

Cloudflare Worker that caches public GitLab static objects at the edge. Deployed separately
via `wrangler deploy` (not part of `scripts/deploy.sh`). Run `generate-wrangler.sh` first to create
`wrangler.jsonc` from `.env` values. See [`gitlab-cdn/README.md`](gitlab-cdn/README.md)
for full documentation.

**Key design decisions:**

- **Workers VPC** — the Worker reaches the private GitLab origin through a
  [VPC Service](https://developers.cloudflare.com/workers-vpc/) via the same `cloudflared`
  tunnel. The origin is never exposed publicly. HTTP is used inside the tunnel (QUIC encrypts
  end-to-end).
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

## CI/CD Pipeline

The repo uses a modular CI pipeline defined in `.gitlab-ci.yml` with job files under `.gitlab/ci/`.
All lint jobs run on every push to `main` and on merge request events. The deploy stage runs only
on `main`.

| Stage   | Job              | What it does                                                    |
| ------- | ---------------- | --------------------------------------------------------------- |
| lint    | shellcheck       | Shell script correctness (all `.sh` files + hook scripts)       |
| lint    | shfmt            | Shell formatting (`-i 2 -ci -bn`)                               |
| lint    | prettier         | Markdown, JSON, TypeScript, and YAML formatting                 |
| lint    | markdownlint     | Structural Markdown issues (headings, lists, code fences)       |
| lint    | codespell        | Common typos across all files                                   |
| lint    | printf-check     | No bare `echo` usage in scripts (heredoc blocks exempt)         |
| lint    | executable-check | Verify `+x` bit on scripts                                      |
| deploy  | mirror-github    | Force-pushes `main` and tags to GitHub                          |
| release | release-gitlab   | Creates a GitLab release with notes from git-cliff (tag pushes) |
| release | release-github   | Creates a matching GitHub release via REST API (tag pushes)     |

> Secret detection is handled by the `detect-secrets` pre-receive server hook, which blocks
> pushes containing leaked credentials before they enter the repo. See
> [`optional/README.md`](optional/README.md) for details.

### Runner requirements

Jobs may run on any registered runner. Tools required by CI jobs must be installed on **all**
runner hosts:

| Tool              | Required by    | Install method                     |
| ----------------- | -------------- | ---------------------------------- |
| shellcheck        | shellcheck     | `apt-get install shellcheck`       |
| shfmt             | shfmt          | Binary from GitHub Releases        |
| node + npm        | prettier       | NodeSource (Node 22 LTS)           |
| markdownlint-cli2 | markdownlint   | `npm install -g markdownlint-cli2` |
| codespell         | codespell      | `pip3 install codespell`           |
| git               | mirror-github  | `apt-get install git`              |
| git-cliff         | release-gitlab | `npm install -g git-cliff`         |
| release-cli       | release-gitlab | Binary from GitLab Releases        |
| jq                | release-github | `apt-get install jq`               |

The `runner-apps.sh` script installs most of these. Use `update-runners.sh` to install all tools
on every runner in one command.

### Releases

Releases are created automatically when a semver tag (`v*.*.*`) is pushed. The release pipeline:

1. `mirror-github` pushes the tag to GitHub
2. `release-gitlab` uses [git-cliff](https://git-cliff.org/) to generate release notes from
   Conventional Commit history, then creates a GitLab release via `release-cli`
3. `release-github` creates a matching release on GitHub via the REST API

Release notes are generated from git history by [git-cliff](https://git-cliff.org/) at tag time.
No changelog file is committed to the repo. Release notes live on the
[GitLab Releases](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/releases) and
[GitHub Releases](https://github.com/FlarelyLegal/cf-gitlab/releases) pages.

To tag a release after merging to `main`:

```bash
# Preview what the next version and notes will look like
git-cliff --bump --unreleased

# Tag the current main (git-cliff --bump infers the version from commit types)
git tag -s v1.x.x
git push origin v1.x.x
```

The tag push triggers the release pipeline, which generates notes and creates releases on both
GitLab and GitHub automatically.

The `cliff.toml` config controls changelog formatting: Keep a Changelog section names,
Conventional Commit type grouping, author attribution, and commit SHA links to the self-hosted
GitLab instance.

---

## Repository Mirroring

The repo is hosted on a self-hosted GitLab instance and mirrored to two external platforms:

```text
local push → self-hosted GitLab (origin)
                ├── CI pipeline runs lint + deploy stage
                │   └── mirror-github job → GitHub (force push)
                └── push mirror (built-in) → gitlab.com
```

- **GitHub** (`https://github.com/FlarelyLegal/cf-gitlab`) is updated by the `mirror-github` CI
  job in the deploy stage. It uses a masked CI/CD variable (`gitlab_self_hosted_mirror`) containing
  a GitHub Personal Access Token with `public_repo` scope. The job runs `git push --force` to
  keep GitHub in sync after all lint checks pass.

- **gitlab.com** (`https://gitlab.com/tim548/gitlab-self-hosted`) is updated by GitLab's built-in
  push mirror feature. This runs automatically on every push to the self-hosted instance, independent
  of CI. CI/CD is disabled on the gitlab.com mirror to prevent shared runners from running the pipeline.

> The local `origin` remote fetches from GitHub (for redundancy) but pushes only to the self-hosted
> GitLab instance. This ensures all code goes through the self-hosted CI pipeline and server hooks
> before reaching external mirrors.

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
the co-located shell executor. Two scripts handle this:

- **`runners/deploy-runner.sh`** runs locally, pushes config and scripts to the runner LXC, then
  executes the setup remotely (same pattern as `scripts/deploy.sh` for the GitLab LXC).
- **`runners/external-runner.sh`** runs on the runner LXC itself, installs and registers the
  runner via the GitLab API, configures UFW, and installs CI tools from `runner-apps.json`.

### Before you start

- A separate Debian 13 LXC with root SSH access from your workstation
- A GitLab Personal Access Token with `create_runner` scope
- `GITLAB_DOMAIN`, `ORG_NAME`, `ORG_URL` set in `.env`

### Deploy

```bash
# Dry run first
RUNNER_LXC_HOST=root@<runner-ip> \
RUNNER_GITLAB_PAT=<your-personal-access-token> \
RUNNER_RUNNER_NAME=runner-1 \
RUNNER_RUNNER_TAGS=linux,x64 \
  ./runners/deploy-runner.sh --dry-run

# Deploy
RUNNER_LXC_HOST=root@<runner-ip> \
RUNNER_GITLAB_PAT=<your-personal-access-token> \
RUNNER_RUNNER_NAME=runner-1 \
RUNNER_RUNNER_TAGS=linux,x64 \
  ./runners/deploy-runner.sh
```

| Variable                | Default                      | Description                               |
| ----------------------- | ---------------------------- | ----------------------------------------- |
| `RUNNER_LXC_HOST`       | (required)                   | SSH target for the runner LXC             |
| `RUNNER_GITLAB_PAT`     | (required)                   | PAT with `create_runner` scope            |
| `RUNNER_RUNNER_NAME`    | `runner-1`                   | Runner description shown in GitLab admin  |
| `RUNNER_RUNNER_TAGS`    | `linux,x64`                  | Comma-separated tags for job matching     |
| `RUNNER_SSH_ALLOW_CIDR` | `SSH_ALLOW_CIDR` from `.env` | CIDR for UFW SSH access on the runner LXC |

### What happens on the runner LXC (`external-runner.sh`)

1. Sets MOTD with runner info
2. Configures UFW (default deny incoming, SSH from `SSH_ALLOW_CIDR`)
3. Adds GitLab Runner APT repository
4. Installs `gitlab-runner` + helper images
5. Creates a runner authentication token via GitLab API (`POST /api/v4/user/runners`)
6. Registers the runner (shell executor, `glrt-` token flow)
7. Starts and verifies the runner service
8. Installs CI tools from `runner-apps.json` via `runner-apps.sh`

The script is idempotent. If a runner with the same name already exists, creation is skipped.

> The deploy script runs `external-runner.sh` inside a `screen` session on the runner LXC,
> so the setup survives SSH disconnects. Progress is streamed back to your terminal in real time.

**Verify:** Go to `https://gitlab.example.com/admin/runners`. The runner should appear as online.

### Runner tool requirements

CI jobs may run on any registered runner. If you add new CI checks (linters, formatters, etc.),
install the required tools on **all** runner hosts, not just one. The `runner-apps.sh` script
handles bulk installation from `runner-apps.json`, but tools installed manually (like `shfmt`,
`codespell`, or `markdownlint-cli2`) must be installed on each runner separately.

---

## Issues

Open issues on [GitHub](https://github.com/FlarelyLegal/cf-gitlab/issues).
They are automatically mirrored to the self-hosted GitLab instance via a
[GitHub Actions workflow](.github/workflows/sync-issues.yml).

---

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
