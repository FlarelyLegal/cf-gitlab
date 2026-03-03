[root](../README.md) / **config**

# Config

Static data files used by the deploy and setup scripts.

| File          | Used by                                                            | Description                                  |
| ------------- | ------------------------------------------------------------------ | -------------------------------------------- |
| `banner.txt`  | `scripts/motd.sh`, `scripts/deploy.sh`, `runners/deploy-runner.sh` | ASCII art banner for the MOTD                |
| `chrony.conf` | `cloudflare/timing.sh`, `scripts/deploy.sh`                        | Chrony config (time.cloudflare.com with NTS) |
