# Shell Conventions

## printf, Not echo

The `printf-check.yml` CI template enforces this as a **CI gate** — bare
`echo` usage in shell scripts fails the pipeline. The only exception is
`echo` inside heredoc blocks (`cat <<`).

Use:

```shell
printf "Deploying %s to %s\n" "${NAME}" "${TARGET}"
```

Never:

```shell
echo "Deploying $NAME to $TARGET"
```

## Variable Quoting

Always quote variable expansions with braces and double quotes:

```shell
"${VAR_NAME}"
```

For variables that may be unset, use the default-empty syntax to prevent
unbound variable errors:

```shell
"${VAR_NAME:-}"
```

## Script Header

Every script starts with `set -euo pipefail` and a comment-header block:

```shell
#!/usr/bin/env bash
set -euo pipefail

# ─── Script Name ──────────────────────────────────────────────────────────
# Brief description of what this script does.
```

## --dry-run Support

Every deployment script must support `--dry-run`. Use a boolean flag:

```shell
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done
```

Guard destructive operations:

```shell
if ${DRY_RUN}; then
  printf '[dry-run] Would run: gitlab-ctl reconfigure\n'
else
  gitlab-ctl reconfigure
fi
```

## YAML Multiline Script Styles

Three distinct styles:

- `|` (literal block): multi-line shell with control flow (`if`/`for`/`while`)
- `>-` (folded, no trailing newline): single long commands split across lines
- `-` (list items): sequential independent commands

## SSH/SCP Patterns

Deployment scripts use consistent SSH options for reliability:

```shell
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o BatchMode=yes)
```

## Progress Reporting

Scripts that perform multiple steps use numbered progress indicators:

```shell
printf '\n── Step %d/%d: %s ──\n' "${step}" "${total}" "${description}"
```

## JSON Escaping in Shell

When sending data to APIs, use Python for JSON escaping:

```shell
ESCAPED=$(printf '%s' "${TEXT}" | python3 -c "import sys,json;print(json.dumps(sys.stdin.read()))")
```
