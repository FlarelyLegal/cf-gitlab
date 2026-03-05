[root](../../README.md) / [runners](../README.md) / **container**

# LXC Container Provisioning

One-shot script that runs on a Proxmox host to create a fully-configured Debian 13 LXC container. Feature flags control what gets installed. Everything is pinned by hash or version for reproducibility.

## Quick Start

```bash
# 1. Copy config and SSH keys, fill in secrets
cp gitlab-runner-container.env.example gitlab-runner-container.env
cp sshkeys.txt.example sshkeys.txt
vi gitlab-runner-container.env sshkeys.txt

# 2. Copy to Proxmox host
scp gitlab-runner-container.sh gitlab-runner-container.env sshkeys.txt banner-runner.txt root@proxmox:/root/

# 3. Validate (works from any machine)
ssh root@proxmox 'bash /root/gitlab-runner-container.sh --dry-run'

# 4. Provision
ssh root@proxmox 'bash /root/gitlab-runner-container.sh'
```

## What Gets Provisioned

The script creates a Debian 13 LXC and conditionally installs components based on feature flags:

| Feature flag                | What it installs                                                 |
| --------------------------- | ---------------------------------------------------------------- |
| `INSTALL_DOCKER=yes`        | Docker CE (pinned versions, held from upgrades), MTU from `.env` |
| `INSTALL_DOCKGE=yes`        | Dockge Docker UI (pinned digest), auto-deploys compose stacks    |
| `INSTALL_GITLAB_RUNNER=yes` | GitLab Runner (API registration, `glrt-` token, systemd limits)  |
| `INSTALL_NODEJS=yes`        | Node.js from NodeSource, optional NPM globals                    |
| `INSTALL_TERRAFORM=yes`     | Terraform from HashiCorp                                         |
| `INSTALL_OPENTOFU=yes`      | OpenTofu                                                         |
| `INSTALL_BUILD_TOOLS=yes`   | build-essential, python3, pip, optional pip packages             |
| `INSTALL_UFW=yes`           | UFW firewall (deny inbound, allow outbound, Docker forwarding)   |

Every container also gets: SSH key injection, locale config, sysctl tuning, MOTD banner, and a `/health` JSON endpoint (systemd socket-activated, zero idle cost).

## Configuration Reference

All config lives in a single `.env` file. Variables marked **required** must be set; others have sensible defaults. See [`gitlab-runner-container.env.example`](gitlab-runner-container.env.example) for the full template with comments.

### Container Identity

| Variable   | Required | Default                 | Description                           |
| ---------- | -------- | ----------------------- | ------------------------------------- |
| `CTID`     | Yes      | `99997`                 | Proxmox container ID (unique integer) |
| `HOSTNAME` | Yes      | `gitlab-runner-2`       | Container hostname                    |
| `PASSWORD` | Yes      | `GitLabRunner-ChangeMe` | Root password                         |

### Resources

| Variable    | Required | Default | Description                 |
| ----------- | -------- | ------- | --------------------------- |
| `CORES`     | Yes      | `8`     | CPU cores                   |
| `MEMORY`    | Yes      | `8192`  | RAM in MB                   |
| `SWAP`      | No       | `0`     | Swap in MB (`0` to disable) |
| `DISK_SIZE` | Yes      | `40`    | Root disk in GB             |

### Network

| Variable       | Required | Default           | Description                               |
| -------------- | -------- | ----------------- | ----------------------------------------- |
| `NET_ID`       | No       | `net0`            | Proxmox network device identifier         |
| `NET_NAME`     | No       | `eth0`            | Interface name inside the container       |
| `BRIDGE`       | No       | `vmbr1`           | Proxmox bridge to attach to               |
| `IP`           | Yes      | `10.1.1.102/24`   | IP with CIDR                              |
| `GATEWAY`      | Yes      | `10.1.1.254`      | Default gateway                           |
| `MTU`          | No       | `1500`            | Network MTU (set `9000` for jumbo frames) |
| `VLAN`         | No       | `1111`            | 802.1Q VLAN tag                           |
| `NAMESERVER`   | Yes      | `10.1.1.254`      | DNS server                                |
| `SEARCHDOMAIN` | Yes      | `lab.example.com` | DNS search domain                         |

### Container Settings

| Variable       | Required | Default                     | Description                                               |
| -------------- | -------- | --------------------------- | --------------------------------------------------------- |
| `UNPRIVILEGED` | No       | `1`                         | Unprivileged container (`1`=yes)                          |
| `ONBOOT`       | No       | `1`                         | Start on Proxmox boot                                     |
| `TIMEZONE`     | No       | `America/New_York`          | Timezone                                                  |
| `FEATURES`     | No       | `nesting=1,keyctl=1,fuse=1` | LXC features                                              |
| `PCT_TAGS`     | No       | `runner;gitlab`             | Proxmox UI tags (semicolon-separated, **must be quoted**) |
| `FIX_LOCALE`   | No       | `yes`                       | Install and configure `en_US.UTF-8` locale                |

### Template

| Variable            | Required | Default                                   | Description                             |
| ------------------- | -------- | ----------------------------------------- | --------------------------------------- |
| `TEMPLATE`          | Yes      | `debian-13-standard_13.1-2_amd64.tar.zst` | Template filename                       |
| `TEMPLATE_STORAGE`  | Yes      | `local`                                   | Proxmox storage for templates           |
| `TEMPLATE_SHA256`   | No       | --                                        | SHA-256 hash for integrity verification |
| `CONTAINER_STORAGE` | Yes      | `local-zfs`                               | Proxmox storage for container rootfs    |

### SSH Keys

Keys are read from `sshkeys.txt` (one per line, comments/blanks ignored). Injected into `authorized_keys` for `root` and `gitlab-runner` (when runner is enabled).

| Variable        | Required | Default       | Description                                   |
| --------------- | -------- | ------------- | --------------------------------------------- |
| `SSH_KEYS_FILE` | No       | `sshkeys.txt` | Path to public keys file (relative to script) |

### Docker

Enabled with `INSTALL_DOCKER=yes`. All five package versions are required when enabled.

| Variable                 | Required | Default | Description                             |
| ------------------------ | -------- | ------- | --------------------------------------- |
| `INSTALL_DOCKER`         | No       | `no`    | Install Docker                          |
| `DOCKER_GPG_SHA256`      | No       | --      | SHA-256 of Docker APT GPG key           |
| `DOCKER_CE_VERSION`      | Cond.    | --      | `docker-ce` package version             |
| `DOCKER_CE_CLI_VERSION`  | Cond.    | --      | `docker-ce-cli` package version         |
| `CONTAINERD_VERSION`     | Cond.    | --      | `containerd.io` package version         |
| `DOCKER_BUILDX_VERSION`  | Cond.    | --      | `docker-buildx-plugin` package version  |
| `DOCKER_COMPOSE_VERSION` | Cond.    | --      | `docker-compose-plugin` package version |
| `DOCKER_MTU`             | No       | `1500`  | Docker daemon MTU (match network MTU)   |

All Docker packages are held (`dpkg --set-selections`) to prevent unintended upgrades.

### Dockge

| Variable              | Required | Default | Description                 |
| --------------------- | -------- | ------- | --------------------------- |
| `INSTALL_DOCKGE`      | No       | `no`    | Install Dockge Docker UI    |
| `DOCKGE_PORT`         | No       | `5001`  | Host port for Dockge web UI |
| `DOCKGE_IMAGE_DIGEST` | Cond.    | --      | Pinned image digest         |

Dockge has no env-based user provisioning. First visit to the web UI prompts admin account creation (stored in SQLite).

### Stacks

Compose stacks in `STACKS_DIR` are automatically deployed into `/opt/stacks/` (managed by Dockge). Each subdirectory needs a `compose.yaml` and optional `.env`. See also [`stacks/`](../../stacks/README.md) for the compose files themselves.

| Variable     | Required | Default    | Description                                                   |
| ------------ | -------- | ---------- | ------------------------------------------------------------- |
| `STACKS_DIR` | No       | `./stacks` | Host directory containing stack subdirectories                |
| `KROKI_PORT` | No       | --         | Kroki host port (used by Kroki compose stack, not the script) |

### GitLab Runner

| Variable                            | Required | Default         | Description                                             |
| ----------------------------------- | -------- | --------------- | ------------------------------------------------------- |
| `INSTALL_GITLAB_RUNNER`             | No       | `no`            | Install and register a GitLab Runner                    |
| `GITLAB_URL`                        | Cond.    | --              | GitLab instance URL                                     |
| `GITLAB_PAT`                        | Cond.    | --              | Personal Access Token (needs `create_runner` scope)     |
| `GITLAB_RUNNER_VERSION`             | Cond.    | --              | APT package version (e.g. `18.9.0-1`)                   |
| `GITLAB_RUNNER_GPG_SHA256`          | No       | --              | SHA-256 of runner repo GPG key                          |
| `GITLAB_RUNNER_EXECUTOR`            | No       | `shell`         | Executor type                                           |
| `GITLAB_RUNNER_TYPE`                | No       | `instance_type` | Scope: `instance_type`, `group_type`, or `project_type` |
| `GITLAB_RUNNER_GROUP_ID`            | Cond.    | --              | Required when type is `group_type`                      |
| `GITLAB_RUNNER_PROJECT_ID`          | Cond.    | --              | Required when type is `project_type`                    |
| `GITLAB_RUNNER_TAGS`                | No       | --              | Comma-separated tags for job routing                    |
| `GITLAB_RUNNER_RUN_UNTAGGED`        | No       | `false`         | Pick up untagged jobs                                   |
| `GITLAB_RUNNER_CONCURRENT`          | No       | `2`             | Max concurrent jobs                                     |
| `GITLAB_RUNNER_LIMIT`               | No       | `1`             | Max jobs per runner                                     |
| `GITLAB_RUNNER_OUTPUT_LIMIT`        | No       | `8192`          | Job log output limit (KB)                               |
| `GITLAB_RUNNER_REQUEST_CONCURRENCY` | No       | `1`             | Concurrent job requests to GitLab                       |
| `RUNNER_CPU_QUOTA`                  | No       | `600%`          | systemd CPUQuota for runner service                     |
| `RUNNER_MEMORY_MAX`                 | No       | `6G`            | systemd MemoryMax for runner service                    |

Registration uses the GitLab API (`POST /api/v4/user/runners`) to create a `glrt-` token, then `gitlab-runner register --non-interactive`. Tags and metadata are managed server-side via the API.

### Node.js

| Variable                | Required | Default | Description                                            |
| ----------------------- | -------- | ------- | ------------------------------------------------------ |
| `INSTALL_NODEJS`        | No       | `no`    | Install Node.js from NodeSource                        |
| `NODEJS_VERSION`        | Cond.    | --      | APT package version                                    |
| `NODESOURCE_GPG_SHA256` | No       | --      | SHA-256 of NodeSource GPG key                          |
| `NPM_GLOBALS`           | No       | --      | Space-separated `pkg@version` list to install globally |

### Terraform / OpenTofu

| Variable                   | Required | Default | Description                      |
| -------------------------- | -------- | ------- | -------------------------------- |
| `INSTALL_TERRAFORM`        | No       | `no`    | Install Terraform from HashiCorp |
| `TERRAFORM_VERSION`        | Cond.    | --      | APT package version              |
| `HASHICORP_GPG_SHA256`     | No       | --      | SHA-256 of HashiCorp GPG key     |
| `INSTALL_OPENTOFU`         | No       | `no`    | Install OpenTofu                 |
| `TOFU_VERSION`             | Cond.    | --      | APT package version              |
| `OPENTOFU_GPG_SHA256`      | No       | --      | SHA-256 of OpenTofu GPG key      |
| `OPENTOFU_REPO_GPG_SHA256` | No       | --      | SHA-256 of OpenTofu repo GPG key |

### Build Tools

| Variable              | Required | Default | Description                                                     |
| --------------------- | -------- | ------- | --------------------------------------------------------------- |
| `INSTALL_BUILD_TOOLS` | No       | `no`    | Install build-essential, python3-dev, python3-pip, python3-venv |
| `PIP_PACKAGES`        | No       | --      | Space-separated `pkg==version` list                             |

### Sysctl / Health / UFW

| Variable                            | Required | Default      | Description                                          |
| ----------------------------------- | -------- | ------------ | ---------------------------------------------------- |
| `SYSCTL_INOTIFY_MAX_USER_INSTANCES` | No       | `65536`      | inotify max user instances                           |
| `SYSCTL_INOTIFY_MAX_USER_WATCHES`   | No       | --           | inotify max user watches (enables tuning when set)   |
| `SYSCTL_INOTIFY_MAX_QUEUED_EVENTS`  | No       | `8388608`    | inotify max queued events                            |
| `HEALTH_PORT`                       | No       | `5000`       | TCP port for `/health` JSON endpoint                 |
| `INSTALL_UFW`                       | No       | `no`         | Install and configure UFW                            |
| `UFW_ALLOW_FROM`                    | No       | `10.0.0.0/8` | CIDR to allow inbound from                           |
| `UFW_INBOUND_PORTS`                 | No       | `22`         | Space-separated ports to allow from `UFW_ALLOW_FROM` |

Health endpoint returns HTTP 200 (`{"status":"healthy",...}`) or 503 (`{"status":"degraded",...}`). UFW default policy: deny inbound, allow outbound, allow routed (Docker forwarding via `NET_NAME` -> `docker0`).

## Multiple Containers

Each container needs its own `.env` with a unique CTID, hostname, and IP:

```bash
cp gitlab-runner-container.env runner-3.env
# Edit: CTID=99996, HOSTNAME=gitlab-runner-3, IP=10.1.1.103/24
ssh root@proxmox 'bash /root/gitlab-runner-container.sh runner-3.env'
```

For a Docker/Dockge-only container (no runner), set `INSTALL_GITLAB_RUNNER=no` and disable the toolchain flags.

## Tear Down and Rebuild

```bash
pct stop 99997 && pct destroy 99997
bash /root/gitlab-runner-container.sh
```
