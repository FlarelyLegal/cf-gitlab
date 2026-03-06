# CI/CD

## What This Repo Is

This is the deployment toolkit for a self-hosted GitLab CE instance on Debian
13 (Trixie) LXC, integrated with the Cloudflare ecosystem. Shell scripts
handle provisioning, configuration, and ongoing maintenance. A TypeScript
Cloudflare Worker (`gitlab-cdn/`) provides CDN caching.

## Pipeline

Defined in `.gitlab-ci.yml` with five stages: `lint-fast`, `lint`, `test`,
`deploy`, `release`.

All linting and quality jobs come from the shared
`flarely-legal/ci-templates` project via `include:`. The only locally-defined
job is `cdn:test`, which runs Vitest on the CDN Worker.

## Stages

| Stage       | Purpose                                                                                         |
| ----------- | ----------------------------------------------------------------------------------------------- |
| `lint-fast` | Quick shell checks (shfmt, shellcheck, printf-check, executable-check)                          |
| `lint`      | Heavier linters with artifacts (prettier, markdownlint, yamllint, codespell, gitleaks, semgrep) |
| `test`      | Unit tests (`cdn:test` runs Vitest on `gitlab-cdn/`)                                            |
| `deploy`    | Push/mirror to external targets                                                                 |
| `release`   | Create release objects on GitLab/GitHub                                                         |

## Runners

Shell executors on Debian trixie. Runner tools are installed system-wide via
`runners/runner-apps.sh` from the manifest in `runners/runner-apps.json`.

## Included Templates

From `flarely-legal/ci-templates` (ref: `main`):

- shellcheck, shfmt, prettier, markdownlint, codespell
- printf-check, executable-check, yamllint, gitleaks, semgrep
- mr-description-check, auto-label, deploy, release

## Workflow Rules

Duplicate pipelines are prevented: if a branch push has an open MR, only the
MR pipeline runs. Tag pushes create release pipelines.

## Variable Naming Convention

- **lowercase_snake** for actual secrets (masked variables):
  `gitlab_self_hosted_mirror`, `gitlab_com_release_token`
- **SCREAMING_SNAKE** for non-secret configuration:
  `GITHUB_REPO`, `GITLAB_COM_PROJECT_ID`

## Secrets

- Sensitive values (API tokens, PATs) live in GitLab CI/CD variables, never
  in committed files.
- The `.env` file is gitignored and never committed.
- The `detect-secrets` pre-receive server hook blocks pushes containing
  leaked credentials before they enter the repo.
