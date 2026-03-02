# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

## 2026-03-02

### Added

- `update-runners.sh` orchestrator that reads `RUNNER_HOSTS` from `.env` and SSHes into each runner to run `runner-apps.sh` idempotently (`afaaf75e`)
- pip and standalone binary support in `runner-apps.sh` (codespell via pip3, shfmt via GitHub releases) (`afaaf75e`)
- `RUNNER_HOSTS` variable in `.env.example` (`afaaf75e`)
- `workflow: rules` in `.gitlab-ci.yml` to prevent duplicate pipelines when a branch push has an open MR (`37833d87`)
- Path-based `rules: changes:` filters on all lint jobs so they only run when relevant files change (`47183420`)
- `allow_failure: true` on codespell job (advisory, won't block MRs) (`47183420`)
- `prettier`, `eslint`, `@eslint/js` to `gitlab-cdn/package.json` devDependencies (`2290a894`)
- `pip` and `binary` sections to `runner-apps.json` manifest (`2290a894`)
- CI/CD Pipeline section in README with job table and runner tool requirements (`72626ffa`)
- Repository Mirroring section documenting local, self-hosted GitLab, GitHub, and gitlab.com flow (`72626ffa`)
- Step 11 (Install Hooks) with server hook and file hook install commands (`72626ffa`)
- Full External Self-Hosted Runner documentation (`72626ffa`)
- Cloudflare Access OIDC instructions split into Self-hosted app (5a) and SaaS OIDC app (5b) with exact dashboard steps (`34981bd8`)
- `detect-secrets` pre-receive server hook with 94 patterns, combined regex fast-path, `.secret-detection-allowlist` (`14eaa624`)
- `.gitlab-ci.yml` with ShellCheck lint stage (`14eaa624`)
- Pre-receive server hooks for branch naming, blocked file extensions, and Conventional Commit enforcement (`2ceaa90b`)
- File hook for admin notifications on project, group, and user events (`31106401`)
- Discord failed-login file hook (`c1b99cf8`)
- External runner scripts: `deploy-runner.sh` and `external-runner.sh` (`d3d525c1`)
- `runner-apps.json` manifest and `runner-apps.sh` installer (`d3d525c1`)
- SMTP section and screen session tips in README (`9d745ae6`)
- Proxmox community scripts reference for Debian LXC creation (`f93ba7ab`)
- Cloudflare, GitLab, Debian, and license badges to README (`4b4f1eb4`)
- Initial release: `setup.sh`, `deploy.sh`, `validate.sh`, `ssonly.sh`, `motd.sh`, `ssh-config.sh`, CDN Worker, Cloudflare scripts (WAF, cache, rate-limit, NTS, R2), and full README (`21fad90d`)

### Changed

- Environment variables section restructured from one table into 6 grouped subheadings (`89e04894`)
- Cloudflare dashboard URLs updated from `one.dash.cloudflare.com` to `dash.cloudflare.com/one` (`5e07f84f`)
- Tunnel nav path updated from "Networks, Tunnels" to "Networks, Connectors, Cloudflare Tunnels" (`5e07f84f`)
- "VPC Service Binding" terminology updated to "Workers VPC" / "VPC Service" with new doc links (`5e07f84f`)
- Removed unnecessary "Disable Chunked Encoding" from SSH tunnel instructions (`5e07f84f`)
- `deploy.yml` now uses `$CI_DEFAULT_BRANCH` instead of hardcoded `"main"` (`37833d87`)
- Redundant per-job `rules:` removed from all 7 lint jobs (now inherited from `workflow: rules`) (`37833d87`)
- `markdownlint-cli` replaced with `markdownlint-cli2` in `runner-apps.json` (`2290a894`)
- Removed redundant Repository Structure section from README (`13bd070c`)
- CI pipeline modularized into `.gitlab/ci/` directory with 8 job files (`68f003b3`)
- GitHub mirror changed from direct push to CI-driven job (`bd0abb53`)
- Repo reorganized into subdirectories: `cloudflare/`, `runners/`, `config/`, `optional/`, `snippets/`, `gitlab-cdn/` (`c1b99cf8`)
- README title changed to "Self-Hosted GitLab with Cloudflare" (`d20b5a7b`)
- LICENSE changed to GPL-3.0

### Fixed

- sed delimiter in `runner-apps.sh` for scoped npm packages like `@eslint/js` (used `#` instead of `/`) (`afaaf75e`)
- shfmt formatting in `generate-wrangler.sh` (`faa23400`)
- Correct CI variable name for GitHub mirror PAT (`05c7415c`)
- Runner token heredoc bug causing Ruby interpolation failure (`56aeea1c`)
- Server hooks path corrected to `/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/` (`14eaa624`)
- R2 account ID resolution in `validate.sh` (`c1b99cf8`)
- Health endpoint 404 caused by `X-Forwarded-For` blocking (added `monitoring_whitelist`) (`21fad90d`)
