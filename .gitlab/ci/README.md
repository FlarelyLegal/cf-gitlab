[root](../../README.md) / **.gitlab/ci**

# CI Job Definitions (Reference Copies)

These files are **reference copies** of the CI job definitions. The live versions used by the pipeline are in the [`flarely-legal/ci-templates`](https://gitlab.flarelylegal.com/flarely-legal/ci-templates) project, referenced via `include:project` in the root `.gitlab-ci.yml`.

If you need to update a CI job, edit it in the `ci-templates` project. These local copies are kept for readability so contributors can see the pipeline structure without navigating to a separate repo.

| File                   | Stage   | Description                                               |
| ---------------------- | ------- | --------------------------------------------------------- |
| `shellcheck.yml`       | lint    | Shell script correctness (all `.sh` files + hook scripts) |
| `shfmt.yml`            | lint    | Shell formatting (`-i 2 -ci -bn`)                         |
| `prettier.yml`         | lint    | Markdown, JSON, TypeScript, and YAML formatting           |
| `markdownlint.yml`     | lint    | Structural Markdown issues (headings, lists, code fences) |
| `codespell.yml`        | lint    | Common typos across all files                             |
| `printf-check.yml`     | lint    | No bare `echo` usage in scripts (heredoc blocks exempt)   |
| `executable-check.yml` | lint    | Verify `+x` bit on scripts                                |
| `deploy.yml`           | deploy  | Force-pushes `main` and tags to GitHub                    |
| `release.yml`          | release | Creates GitLab + GitHub releases with git-cliff notes     |
