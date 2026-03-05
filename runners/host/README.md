[root](../../README.md) / [runners](../README.md) / **host**

# External Runner (Existing Host)

Deploys a GitLab Runner to a separate Debian LXC (or any host) you've already created. Two scripts: `deploy-runner.sh` runs locally and pushes config, `external-runner.sh` runs on the target host and handles installation + registration via the GitLab API.

## Quick Start

```bash
# Dry run first
RUNNER_LXC_HOST=root@<runner-ip> \
RUNNER_GITLAB_PAT=<your-pat> \
RUNNER_RUNNER_NAME=runner-1 \
RUNNER_RUNNER_TAGS=linux,x64 \
  ./runners/host/deploy-runner.sh --dry-run

# Deploy
RUNNER_LXC_HOST=root@<runner-ip> \
RUNNER_GITLAB_PAT=<your-pat> \
RUNNER_RUNNER_NAME=runner-1 \
RUNNER_RUNNER_TAGS=linux,x64 \
  ./runners/host/deploy-runner.sh
```

## Prerequisites

- A Debian 13 LXC (or similar) with root SSH access from your workstation
- A GitLab Personal Access Token with `create_runner` scope
- `GITLAB_DOMAIN`, `ORG_NAME`, `ORG_URL` set in the repo root `.env`

## Configuration

All config is passed via environment variables when calling `deploy-runner.sh`:

| Variable                | Default                      | Description                               |
| ----------------------- | ---------------------------- | ----------------------------------------- |
| `RUNNER_LXC_HOST`       | (required)                   | SSH target for the runner host            |
| `RUNNER_GITLAB_PAT`     | (required)                   | PAT with `create_runner` scope            |
| `RUNNER_RUNNER_NAME`    | `runner-1`                   | Runner description shown in GitLab admin  |
| `RUNNER_RUNNER_TAGS`    | `linux,x64`                  | Comma-separated tags for job matching     |
| `RUNNER_SSH_ALLOW_CIDR` | `SSH_ALLOW_CIDR` from `.env` | CIDR for UFW SSH access on the runner LXC |

## What Happens

`deploy-runner.sh` (runs locally):

1. Loads `.env` from repo root, validates `GITLAB_DOMAIN`, `ORG_NAME`, `ORG_URL`
2. Tests SSH connectivity to the target host
3. Pushes `/root/.secrets/runner.env`, scripts, and banner to the target
4. Launches `external-runner.sh` in a `screen` session (survives SSH disconnects)
5. Streams live output back to your terminal

`external-runner.sh` (runs on the target host):

1. Sets MOTD with runner info
2. Configures UFW (default deny incoming, SSH from `SSH_ALLOW_CIDR`)
3. Adds GitLab Runner APT repository
4. Installs `gitlab-runner` + helper images
5. Creates a runner authentication token via GitLab API (`POST /api/v4/user/runners`)
6. Registers the runner (shell executor, `glrt-` token flow)
7. Starts and verifies the runner service
8. Installs CI tools from `runner-apps.json` via [`runner-apps.sh`](../runner-apps.sh)

Both scripts are idempotent. If a runner with the same name already exists, creation is skipped.

## Files

| File                 | Runs on       | Description                                              |
| -------------------- | ------------- | -------------------------------------------------------- |
| `deploy-runner.sh`   | Local machine | Orchestrator (pushes config, launches setup in screen)   |
| `external-runner.sh` | Runner host   | Server-side setup (UFW, install, API registration, etc.) |

CI tool installation uses [`runner-apps.sh`](../runner-apps.sh) and [`runner-apps.json`](../runner-apps.json) from the parent `runners/` directory.

## Verify

After deployment, the runner should appear as online at `https://<GITLAB_DOMAIN>/admin/runners`.
