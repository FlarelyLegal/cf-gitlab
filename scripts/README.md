[root](../README.md) / **scripts**

# Scripts

All scripts support `--dry-run` to preview changes without applying them.

| Script          | Runs on | Description                                                   |
| --------------- | ------- | ------------------------------------------------------------- |
| `deploy.sh`     | local   | Pushes secrets + scripts to LXC, executes `setup.sh`          |
| `setup.sh`      | LXC     | 11-step GitLab CE install (packages, TLS, nginx, R2, crons)   |
| `validate.sh`   | local   | Read-only check of .env, SSH, DNS, R2, OIDC, HTTPS            |
| `ssh-config.sh` | local   | Configures `~/.ssh/config` for git + admin access via tunnel  |
| `sso-only.sh`   | LXC     | Locks down to Cloudflare Access SSO (disables password login) |
| `motd.sh`       | LXC     | Sets `/etc/motd` with instance info                           |
| `webide.sh`     | local   | Configures custom Web IDE extension host domain               |

## `validate.sh`

Read-only check of the full deployment environment:

1. `.env` exists, all 24 required variables set, no `<placeholder>` values
2. SSH connectivity to the LXC (with OS version detection)
3. All local script files present
4. Cloudflare API credentials valid (Global API key), zone accessible
5. DNS records exist for all domains — reports record type and proxy status (warns if DNS-only on tunnel CNAMEs)
6. All 10 R2 buckets exist (requires `CLOUDFLARE_ACCOUNT_ID` in shell or parseable from `R2_ENDPOINT`)
7. OIDC issuer `.well-known/openid-configuration` responds
8. GitLab health endpoint reachable via HTTPS (tunnel check)

## `deploy.sh`

Reads `.env`, validates all variables, tests SSH, then:

1. Creates `/root/.secrets/` on the LXC (mode 700)
2. Writes `gitlab.env` (deployment variables) and `cloudflare.ini` (API token) to secrets dir
3. SCPs `setup.sh`, `motd.sh`, `banner.txt`, `timing.sh`, `chrony.conf` to `/tmp/` on the LXC
4. Executes `setup.sh` remotely via SSH

## `ssh-config.sh`

Configures `~/.ssh/config` and `~/.ssh/known_hosts` for accessing GitLab
through the Cloudflare Tunnel using client-side `cloudflared`:

1. Adds **git access** entry (`Host <GITLAB_DOMAIN>`) — for `git clone`/`push`/`pull` via tunnel
2. Adds **admin access** entry (`Host gitlab-lxc`) — for interactive root SSH via tunnel
3. Scans the server host key from the LXC IP and adds it under the tunnel hostname

All operations are idempotent — existing entries are skipped. Requires `cloudflared` installed
locally and `GITLAB_DOMAIN` + `LXC_HOST` in `.env`.

## `webide.sh`

Configures a custom Web IDE extension host domain (`webide.<GITLAB_DOMAIN>`)
so VS Code static assets are served from the GitLab instance instead of `cdn.web-ide.gitlab-static.net`:

1. Requests a wildcard TLS certificate for `*.webide.<GITLAB_DOMAIN>` via certbot
2. Creates `/etc/gitlab/nginx-custom/webide.conf` server block proxying `/assets/` to Workhorse
3. Adds `custom_nginx_config` include to `gitlab.rb` (if not already present)
4. Runs `gitlab-ctl reconfigure`

Domain is derived from `GITLAB_DOMAIN` — no additional `.env` variables needed. Idempotent.

## `sso-only.sh`

Locks down authentication to Cloudflare Access SSO:

1. Disables signup and password login (application settings)
2. Enables `omniauth_auto_sign_in_with_provider` in `gitlab.rb` (skips login page)
3. Runs `gitlab-ctl reconfigure`

Use `--revert` to re-enable password login. Emergency bypass:
`https://<GITLAB_DOMAIN>/users/sign_in?auto_sign_in=false`
