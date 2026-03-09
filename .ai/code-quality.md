# Code Quality

## Pre-Push Checklist

`jj push` triggers lefthook pre-push hooks automatically. Verify manually if
in doubt:

- `prettier --check` — format YAML, Markdown, JSON
- `markdownlint-cli2` — lint Markdown structure
- `yamllint` — lint YAML files
- `shellcheck` — lint shell scripts
- `shfmt -d` — check shell script formatting
- `codespell` — catch typos
- `CHANGELOG.md` — must be up-to-date (lefthook checks this)

## Standards

- Fix warnings, don't suppress them.
- If a CI job fails, fix the root cause — do not add `allow_failure` to hide
  it.
- Do not edit auto-generated files (`CHANGELOG.md` is managed by git-cliff).

## File Conventions

- Deployment scripts live in `scripts/` and are named `<verb>.sh` or
  `<verb>-<noun>.sh`.
- Server hooks live in `hooks/` and have no `.sh` extension (they use
  shebangs).
- Ruby file hooks in `hooks/` are named `<action>.rb`.
- Shell embedded in YAML `script:` blocks must use `printf` (not `echo`),
  quote all variables, and use `set -euo pipefail` where appropriate.
- Every script starts with the `# ───` comment-header style explaining what
  it does.
