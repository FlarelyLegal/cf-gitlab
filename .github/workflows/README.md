[root](../../README.md) / **.github/workflows**

# GitHub Actions Workflows

Workflows that run on GitHub (not on the self-hosted GitLab instance).

| Workflow                           | Trigger                  | Description                                              |
| ---------------------------------- | ------------------------ | -------------------------------------------------------- |
| [sync-issues.yml](sync-issues.yml) | Issue and comment events | Mirrors GitHub issues to the self-hosted GitLab instance |

## Issue Sync

When someone opens an issue on GitHub, the `sync-issues` workflow creates a
corresponding issue on GitLab with a `[GitHub #N]` title prefix and the
`github` label. Subsequent activity is synced automatically:

| GitHub Event    | GitLab Action                       |
| --------------- | ----------------------------------- |
| Issue opened    | Create issue with cross-reference   |
| Issue closed    | Close issue with note               |
| Issue reopened  | Reopen issue with note              |
| Issue edited    | Update title and description        |
| Comment created | Add comment with author attribution |

To close a GitHub issue via a commit message on GitLab, use the full URL:

```text
fix: resolve validation error

Closes https://github.com/FlarelyLegal/cf-gitlab/issues/1
```

The CI mirror pushes the commit to GitHub, which auto-closes the issue.
The close event then triggers the sync workflow to close the GitLab copy.

### Required GitHub Secrets

| Secret        | Value                           |
| ------------- | ------------------------------- |
| `GITLAB_PAT`  | GitLab personal access token    |
| `GITLAB_HOST` | GitLab hostname (no `https://`) |
