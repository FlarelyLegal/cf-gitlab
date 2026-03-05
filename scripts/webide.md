[root](../README.md) / [scripts](README.md) / **webide**

# Web IDE Extension Host

By default the Web IDE loads VS Code assets from GitLab's CDN (`cdn.web-ide.gitlab-static.net`).
This script configures a custom extension host domain so assets are served from your own instance.

## Prerequisites

1. Create DNS records: `webide.<GITLAB_DOMAIN>` -> `<GITLAB_DOMAIN>` and `*.webide.<GITLAB_DOMAIN>` -> `webide.<GITLAB_DOMAIN>` (both proxied)
2. Add a Cloudflare Tunnel route for `*.webide.<GITLAB_DOMAIN>`

## Usage

```bash
scripts/webide.sh --dry-run   # preview
scripts/webide.sh             # configure (cert + nginx + gitlab.rb)
```

## What Happens

1. Requests a wildcard TLS certificate for `*.webide.<GITLAB_DOMAIN>` via certbot
2. Creates `/etc/gitlab/nginx-custom/webide.conf` server block proxying `/assets/` to Workhorse (listens on port 80 for Cloudflare Tunnel and 443 for direct access)
3. Adds `custom_nginx_config` include to `gitlab.rb` (if not already present)
4. Runs `gitlab-ctl reconfigure`
5. Enables feature flags, creates OAuth app, sets extension host domain

A validation summary prints at the end with ✓/✗ for each component.

> If using Cloudflare Access or WAF rules, ensure `*.webide.<GITLAB_DOMAIN>` is
> excluded or allowed -- the extension host serves static assets and must be reachable
> without authentication.
