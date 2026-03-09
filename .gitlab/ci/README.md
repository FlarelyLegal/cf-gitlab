[root](../../README.md) / **.gitlab/ci**

# CI Job Definitions (Reference Copies)

These files are **reference copies** of the CI job definitions. The live versions used by the pipeline are in the [`flarely-legal/ci-templates`](https://gitlab.flarelylegal.com/flarely-legal/ci-templates) project, referenced via `include: component:` in the root `.gitlab-ci.yml`.

If you need to update a CI job, edit it in the `ci-templates` project. These local copies are kept for readability so contributors can see the pipeline structure without navigating to a separate repo.

| File                       | Stage     | Description                                                             |
| -------------------------- | --------- | ----------------------------------------------------------------------- |
| `shellcheck.yml`           | lint-fast | Shell script correctness (all `.sh` files + hook scripts)               |
| `shfmt.yml`                | lint-fast | Shell formatting (`-i 2 -ci -bn`)                                       |
| `printf-check.yml`         | lint-fast | No bare `echo` usage in scripts (heredoc blocks exempt)                 |
| `executable-check.yml`     | lint-fast | Verify `+x` bit on scripts                                              |
| `prettier.yml`             | lint      | Markdown, JSON, TypeScript, and YAML formatting                         |
| `markdownlint.yml`         | lint      | Structural Markdown issues (headings, lists, code fences)               |
| `codespell.yml`            | lint      | Common typos across all files                                           |
| `yamllint.yml`             | lint      | YAML syntax and style validation                                        |
| `gitleaks.yml`             | lint      | Secret detection scan (diff-only on MR, latest on default)              |
| `mr-description-check.yml` | .pre      | Validates merge request description is not empty                        |
| `deploy.yml`               | deploy    | Force-pushes `main` and tags to GitHub (now `mirror-github` in catalog) |
| `release.yml`              | release   | Creates GitLab + GitHub releases (now `gitlab-release` in catalog)      |
