[root](../README.md) / **config**

# Config

Static data files used by the deploy and setup scripts.

| File          | Used by                                                            | Description                                  |
| ------------- | ------------------------------------------------------------------ | -------------------------------------------- |
| `banner.txt`  | `scripts/motd.sh`, `scripts/deploy.sh`, `runners/deploy-runner.sh` | ASCII art banner for the MOTD                |
| `chrony.conf` | `cloudflare/timing.sh`, `scripts/deploy.sh`                        | Chrony config (time.cloudflare.com with NTS) |
| `icons/`      | —                                                                  | Branding assets (favicon, logos, etc.)       |

Icons in `icons/` are sourced from [Dashboard Icons](https://dashboardicons.com/) ([GitHub](https://github.com/homarr-labs/dashboard-icons)).
