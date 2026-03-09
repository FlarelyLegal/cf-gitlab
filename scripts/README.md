[root](../README.md) / **scripts**

# Scripts

All scripts support `--dry-run` to preview changes without applying them.

| Script                | Runs on | Description                                                  |
| --------------------- | ------- | ------------------------------------------------------------ |
| `deploy.sh`           | local   | Pushes secrets + scripts to LXC, executes `setup.sh`         |
| `setup.sh`            | LXC     | 11-step GitLab CE install (packages, TLS, nginx, R2, crons)  |
| `validate.sh`         | local   | Read-only check of .env, SSH, DNS, R2, OIDC, HTTPS           |
| `ssh-config.sh`       | local   | Configures `~/.ssh/config` for git + admin access via tunnel |
| `sso-only.sh`         | LXC     | SSO lockdown ([details](sso-only.md))                        |
| `motd.sh`             | LXC     | Sets `/etc/motd` with instance info                          |
| `webide.sh`           | local   | Web IDE extension host ([details](webide.md))                |
| `deploy-glitchtip.sh` | local   | Deploy GlitchTip stack to target host                        |
| `deploy-kroki.sh`     | local   | Deploy Kroki diagram stack to target host                    |

## Additional Docs

| Doc                          | Description                                     |
| ---------------------------- | ----------------------------------------------- |
| [`smtp.md`](smtp.md)         | SMTP configuration for notification emails      |
| [`sso-only.md`](sso-only.md) | SSO-only lockdown, revert, and emergency access |
| [`webide.md`](webide.md)     | Web IDE extension host setup                    |

## `validate.sh`

Read-only check of the full deployment environment:

1. `.env` exists, all 24 required variables set, no `<placeholder>` values
2. SSH connectivity to the LXC (with OS version detection)
3. All local script files present
4. Cloudflare API credentials valid (Global API key), zone accessible
5. DNS records exist for all domains -- reports record type and proxy status (warns if DNS-only on tunnel CNAMEs)
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

1. Adds **git access** entry (`Host <GITLAB_DOMAIN>`) -- for `git clone`/`push`/`pull` via tunnel
2. Adds **admin access** entry (`Host gitlab-lxc`) -- for interactive root SSH via tunnel
3. Scans the server host key from the LXC IP and adds it under the tunnel hostname

All operations are idempotent -- existing entries are skipped. Requires `cloudflared` installed
locally and `GITLAB_DOMAIN` + `LXC_HOST` in `.env`.
