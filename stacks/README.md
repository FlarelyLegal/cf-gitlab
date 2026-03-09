[root](../README.md) / **stacks**

# Docker Compose Stacks

Docker Compose services that run alongside GitLab. Each stack lives in its own subdirectory with a `compose.yaml` and `.env.example`.

## Stacks

| Directory    | Service                                                                       | Runs on    |
| ------------ | ----------------------------------------------------------------------------- | ---------- |
| `caddy/`     | Reverse proxy with Docker label auto-discovery, Certbot DNS-01 via Cloudflare | GitLab LXC |
| `glitchtip/` | Sentry-compatible error tracking with OIDC support                            | GitLab LXC |
| `kroki/`     | Diagram renderer (PlantUML, Mermaid, GraphViz, BPMN, Excalidraw, D2, C4...)   | GitLab LXC |

## Deployment

Stacks are deployed to `/opt/stacks/<stack>/` on the target host. Two deployment methods:

**Automatic** -- The [LXC provisioning script](../runners/container/README.md) auto-deploys stacks from its `STACKS_DIR` (default: `./stacks` next to the script) into Dockge during container creation. Place stack directories there and they are copied and started automatically.

**Manual:**

```bash
# Copy example env and adjust if needed
cp stacks/<stack>/.env.example /opt/stacks/<stack>/.env

# Copy compose file
cp stacks/<stack>/compose.yaml /opt/stacks/<stack>/compose.yaml

# Start
cd /opt/stacks/<stack> && docker compose up -d

# Check health
docker compose ps
```

The `.env.example` contains no secrets and can be committed as-is.
