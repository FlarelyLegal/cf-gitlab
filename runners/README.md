[root](../README.md) / **runners**

# Runners

GitLab CI runner deployment and management. Three approaches depending on your setup:

| Approach                                       | When to use                                                         |
| ---------------------------------------------- | ------------------------------------------------------------------- |
| [LXC container provisioning](container/)       | Automated Proxmox LXC creation with Docker, Dockge, pinned versions |
| [External runner on existing host](host/)      | Deploy to a Debian host you've already created                      |
| [Co-located runner](#co-located-on-gitlab-lxc) | Quick setup on the same LXC as GitLab (small trusted teams)         |

## LXC Container Provisioning (Proxmox)

One-shot script that creates a fully-configured Debian 13 LXC on Proxmox with feature flags
controlling what gets installed (Docker, Dockge, GitLab Runner, Node.js, Terraform, etc.).
Everything pinned by hash or version. See [`container/README.md`](container/README.md) for
the full configuration reference.

```bash
# On the Proxmox host
bash /root/gitlab-runner-container.sh --dry-run   # validate
bash /root/gitlab-runner-container.sh              # provision
```

## External Runner (Existing Host)

Deploys a runner to a separate host you've already created. Two scripts:
`deploy-runner.sh` (runs locally, pushes config) and `external-runner.sh` (runs on the host,
installs and registers via GitLab API). See [`host/README.md`](host/README.md) for details.

```bash
RUNNER_LXC_HOST=root@<runner-ip> \
RUNNER_GITLAB_PAT=<your-pat> \
RUNNER_RUNNER_NAME=runner-1 \
RUNNER_RUNNER_TAGS=linux,x64 \
  ./runners/host/deploy-runner.sh --dry-run
```

## Co-located on GitLab LXC

Installs the runner on the same LXC as GitLab. Fine for small trusted teams -- no Docker,
no network isolation. The secrets file (`/root/.secrets/gitlab.env`) must exist from
`scripts/deploy.sh`.

```bash
scp runners/gitlabrunner.sh root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/gitlabrunner.sh --dry-run'
ssh root@<LXC_IP> 'bash /tmp/gitlabrunner.sh'
```

## CI Tool Management

After any runner is registered, install the tools CI jobs need:

```bash
scp -r runners/runner-apps.json runners/runner-apps.sh runners/scripts root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/runner-apps.sh'
```

Use `update-runners.sh` to push tools to all runner hosts at once. The tool manifest
(`runner-apps.json`) defines everything installed on the runner: APT packages, GitLab Runner,
Docker, IaC (Terraform/OpenTofu), Node.js, npm globals, pip packages, standalone binaries,
and custom CI helper scripts.

## Scripts

| Script              | Runs on       | Description                                                                 |
| ------------------- | ------------- | --------------------------------------------------------------------------- |
| `gitlabrunner.sh`   | GitLab LXC    | Co-located runner (creates token via Rails, registers, starts)              |
| `runner-apps.sh`    | Runner host   | Installs CI tools from `runner-apps.json`                                   |
| `runner-apps.json`  | --            | Tool manifest (apt, runner, Docker, IaC, Node, npm, pip, binaries, scripts) |
| `update-runners.sh` | Local machine | Pushes `runner-apps.json`, `runner-apps.sh`, and `scripts/` to all runners  |

All scripts support `--dry-run`.

## Subdirectories

| Directory                           | Description                                                                      |
| ----------------------------------- | -------------------------------------------------------------------------------- |
| [`container/`](container/README.md) | LXC container provisioning for Proxmox (Docker, Dockge, GitLab Runner, etc.)     |
| [`host/`](host/README.md)           | Deploy runner to an existing host (local orchestrator + remote setup)            |
| `scripts/`                          | CI helper scripts installed to `/usr/local/bin` (report format converters, etc.) |
