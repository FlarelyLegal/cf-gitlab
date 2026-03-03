[root](../README.md) / **config**

# Config

Static data files used by the deploy and setup scripts.

| File          | Used by                                    | Description                                  |
| ------------- | ------------------------------------------ | -------------------------------------------- |
| `banner.txt`  | `motd.sh`, `deploy.sh`, `deploy-runner.sh` | ASCII art banner for the MOTD                |
| `chrony.conf` | `cloudflare/timing.sh`, `deploy.sh`        | Chrony config (time.cloudflare.com with NTS) |
