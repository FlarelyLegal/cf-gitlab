[root](../README.md) / **stacks**

# Docker Compose Stacks

Docker Compose services that run alongside GitLab. Each stack lives in its own subdirectory with a `compose.yaml` and `.env.example`.

## Stacks

| Directory | Service                                                                   | Runs on    |
| --------- | ------------------------------------------------------------------------- | ---------- |
| `kroki/`  | Diagram renderer (PlantUML, Mermaid, GraphViz, BPMN, Excalidraw, D2, C4…) | GitLab LXC |

## Usage

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

Stacks are deployed to `/opt/stacks/<stack>/` on the target host. The `.env.example` contains no secrets and can be committed as-is.
