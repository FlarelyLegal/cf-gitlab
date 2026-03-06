# Deployment Scripts

## Overview

Scripts in `scripts/` handle provisioning and maintenance of the GitLab LXC.
Scripts in `cloudflare/` configure Cloudflare API resources. Scripts in
`runners/` manage CI runner hosts.

## Script Inventory

### scripts/

| Script            | Purpose                                        |
| ----------------- | ---------------------------------------------- |
| `deploy.sh`       | Push config/scripts to LXC, run setup remotely |
| `setup.sh`        | 11-step GitLab CE install (runs ON the LXC)    |
| `validate.sh`     | Read-only health/config validation             |
| `ssh-config.sh`   | Configure local SSH for tunnel access          |
| `sso-only.sh`     | Lock down to SSO-only login                    |
| `motd.sh`         | Set LXC MOTD with instance info                |
| `webide.sh`       | Web IDE extension host setup                   |
| `deploy-kroki.sh` | Deploy Kroki diagram stack                     |

### runners/

| Script              | Purpose                              |
| ------------------- | ------------------------------------ |
| `gitlabrunner.sh`   | Co-located runner (same LXC)         |
| `runner-apps.sh`    | CI tool installer from manifest      |
| `update-runners.sh` | Push tools to all runner hosts       |
| `container/*.sh`    | Proxmox LXC provisioning for runners |
| `host/*.sh`         | Deploy runner to existing host       |

### cloudflare/

| Script                   | Purpose                      |
| ------------------------ | ---------------------------- |
| `timing.sh`              | Chrony/NTS installer         |
| `waf/waf-rules.sh`       | WAF rule provisioning        |
| `waf/cache-rules.sh`     | Cache rule provisioning      |
| `waf/ratelimit-rules.sh` | Rate limit rule provisioning |

## Design Rules

- Every script must start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Every deployment script must support `--dry-run`.
- Scripts must be idempotent — safe to re-run without side effects.
- Use `trap` for error handling with descriptive failure messages.
- Resolve paths relative to the script, not the working directory:

  ```shell
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  ```

## Environment Variables

Configuration lives in `.env` (gitignored, never committed). Scripts source
it via the deploy script or expect variables to be available in the
environment.

The `.env.example` file documents every required variable with comments.
`shared.env.example` covers variables shared across multiple scripts.

## Server Hooks (optional/)

Shell hooks (no `.sh` extension) are pre-receive hooks installed on the
GitLab server. Ruby hooks (`.rb`) are file hooks triggered by GitLab events.

- `detect-secrets` — blocks pushes containing leaked credentials (94 patterns)
- `enforce-branch-naming` — branch naming convention enforcement
- `enforce-commit-message` — Conventional Commits enforcement
- `enforce-max-file-size` — 10 MB file size limit
- `block-file-extensions` — binary/secret file blocking
- `block-submodule-changes` — submodule prohibition
- `auto-label-projects.rb` — auto-labels new projects with 32 default labels
- `notify-admin.rb` / `discord-failed-login.rb` / `notify-admin-granted.rb` — event notifications
