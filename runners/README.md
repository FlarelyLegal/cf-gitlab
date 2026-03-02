[← Back to root](../README.md)

# Runner Scripts

Scripts for installing and registering GitLab Runners (co-located or external).

| Script               | Runs on       | Description                                                       |
| -------------------- | ------------- | ----------------------------------------------------------------- |
| `gitlabrunner.sh`    | GitLab LXC    | Co-located runner (creates token via Rails, registers, starts)    |
| `deploy-runner.sh`   | Local machine | Orchestrator for external runners (pushes config, runs in screen) |
| `external-runner.sh` | Runner LXC    | Server-side setup (UFW, install, API registration, CI tools)      |
| `runner-apps.sh`     | Runner LXC    | Installs CI tools from `runner-apps.json`                         |
| `runner-apps.json`   | -             | Tool manifest (apt packages, Docker, Node.js, npm globals)        |

All scripts support `--dry-run`. The co-located runner reads from `/root/.secrets/gitlab.env` (created by `deploy.sh`). The external runner reads from `/root/.secrets/runner.env` (created by `deploy-runner.sh`).
