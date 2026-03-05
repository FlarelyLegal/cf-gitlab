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
2. Creates `/etc/gitlab/nginx-custom/webide.conf` server block proxying `/assets/` to Workhorse
3. Adds `custom_nginx_config` include to `gitlab.rb` (if not already present)
4. Runs `gitlab-ctl reconfigure`

Then set the domain in **Admin -> Settings -> General -> Web IDE -> Extension host domain**.

> If using Cloudflare Access or WAF rules, ensure `*.webide.<GITLAB_DOMAIN>` is
> excluded or allowed -- the extension host serves static assets and must be reachable
> without authentication.
