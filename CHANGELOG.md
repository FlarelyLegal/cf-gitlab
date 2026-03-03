# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## [v1.0.1] - 2026-03-03

### Changed

- Replace local CI includes with include:project from ci-templates (FLEGAL-53) ([04bb8747](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/04bb87478dfa84909380cb42ae13d5610f6e1541)) - Timothy Schneider

### Documentation

- Add usage note to cliff.toml header (FLEGAL-52) ([e757b71a](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/e757b71a122c31f8cf9e38b772fba176d891eeb4)) - Timothy Schneider
- Clarify trim comment in cliff.toml (FLEGAL-52) ([04d6bba6](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/04d6bba6fee9377f34759400bb074a03bad92706)) - Timothy Schneider

### Fixed

- Skip snippet repos in enforce-commit-message pre-receive hook (FLEGAL-53) ([221fd615](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/221fd615fd241fbe9f01ad98fc1e7873c50d4093)) - Timothy Schneider
- Use working directory path for release notes file ([4903bdef](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/4903bdef74dcacff8590344426f6d74c1a40981b)) - Timothy Schneider

## [v1.0.0] - 2026-03-02

### Added

- Add release pipeline with git-cliff changelog generation ([4dea043b](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/4dea043b46ea68e30a411b27dc96ab3cd7dce23c)) - Timothy Schneider
- Add update-runners.sh orchestrator and extend runner-apps.sh with pip and binary support ([afaaf75e](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/afaaf75e83982ac9e34be6acb27e6f584f4fa5ad)) - Timothy Schneider
- Add path-based rules and allow_failure for CI lint jobs ([47183420](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/47183420fffccaf342127512d28a75304dbde56f)) - Timothy Schneider
- Add workflow rules to prevent duplicate pipelines ([37833d87](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/37833d87144f5fc74759976e044d1a200de7291d)) - Timothy Schneider
- Add detect-secrets server hook (94 patterns), CI pipeline, fix hooks path ([14eaa624](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/14eaa624b1a22905b3ccfb8a31a3d8c8e1bc86db)) - Timothy Schneider
- Add pre-receive server hooks for branch naming, file extensions, and commit messages ([2ceaa90b](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/2ceaa90bcffaa601c763fad83975f58a7e4234cc)) - Timothy Schneider
- Add file hook for admin notifications (project, group, user events) ([31106401](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/311064017d7ea62124655670602525796091a8e0)) - Timothy Schneider
- Add external runner scripts (deploy-runner.sh, external-runner.sh) ([d3d525c1](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/d3d525c1c412b4e79ae214e22fbfc82b4126f9c3)) - Timothy Schneider
- Initial release of GitLab CE on Debian 13 LXC with Cloudflare integration ([21fad90d](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/21fad90d72dcc2905d8dfc52612344ab329fcca4)) - Timothy Schneider

### Changed

- Fix shfmt formatting in generate-wrangler.sh ([faa23400](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/faa23400c06d35315d55d2d36794c9fd2adbad6c)) - Timothy Schneider
- Add shfmt, codespell, markdownlint, executable-check; auto-format scripts ([b52c9f8c](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/b52c9f8c0eb5717f65c946115999287a1d324263)) - Timothy Schneider
- Add printf-only enforcement check ([82f96cde](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/82f96cdedd549f20c4635db0c78f2354be93409d)) - Timothy Schneider
- Add prettier formatting check ([f7352823](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/f735282387794e9d93fab522636d2cc48a7d7f39)) - Timothy Schneider
- Rename lint.yml to shellcheck.yml for one-job-per-file convention ([a9e0ce38](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/a9e0ce38caafe6f3d501f1048f822701811ac1ff)) - Timothy Schneider
- Modularize CI pipeline into .gitlab/ci/ includes ([68f003b3](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/68f003b3d030084340368488d33b70e65b05b975)) - Timothy Schneider
- Add GitHub mirror job, replace direct push with CI-driven sync ([bd0abb53](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/bd0abb5318a17bc76c69a02d91bb7e2ac3ae2aa7)) - Timothy Schneider
- Reorganize repo structure, add Discord failed-login hook, fix R2 account ID ([c1b99cf8](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/c1b99cf8d553829c39a177f04fd2dd9379d301d2)) - Timothy Schneider

### Documentation

- Add CHANGELOG.md from commit history ([75ec2ed7](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/75ec2ed79204ab85641100681d9c8f93cf492dd5)) - Timothy Schneider
- Update Cloudflare dashboard URLs, tunnel nav paths, and Workers VPC terminology ([5e07f84f](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/5e07f84f67a113138ecffb7445fbb3684d2464cb)) - Timothy Schneider
- Restructure environment variables into grouped subheadings ([89e04894](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/89e048941980f03afc92fd73c6f5aff4d7a489ac)) - Timothy Schneider
- Remove redundant Repository Structure section from README ([13bd070c](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/13bd070c0a0ddace8f162bacb02fbbc1bf5e1f5d)) - Timothy Schneider
- Replace tree diagram with compact directory table in README ([0efdf2de](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/0efdf2debce5f231c1e765cb44ac22b2010ca023)) - Timothy Schneider
- Improve Access OIDC instructions with exact Cloudflare dashboard steps and redirect URL ([34981bd8](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/34981bd86eaefa6aca52880bf7eb31c9bc55596d)) - Timothy Schneider
- Update README with CI pipeline, mirroring, external runner, hooks, and tree diagram ([72626ffa](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/72626ffaeadab1b00eedb4d5fdb4d5c7299f6649)) - Timothy Schneider
- Add SMTP section, screen tips, fix wrangler R2 bucket command ([9d745ae6](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/9d745ae65918a4ca954ad9c35b7b0d696647e2ad)) - Timothy Schneider
- Add Proxmox community scripts reference for Debian LXC creation ([f93ba7ab](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/f93ba7abf804b16de47f5ad36a9d8f9e11fbd5f2)) - Timothy Schneider
- Update README title to Self-Hosted GitLab with Cloudflare ([d20b5a7b](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/d20b5a7bbc6ae1969c86c2f42f854878c733d502)) - Timothy Schneider
- Add Cloudflare, GitLab, Debian, and license badges to README ([4b4f1eb4](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/4b4f1eb4bdd8766cd4844d3306b7b3c88e651176)) - Timothy Schneider

### Fixed

- Add missing devDependencies to package.json and update runner tool manifest ([2290a894](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/2290a8946b60f32fcc362be2792de8f3d087448f)) - Timothy Schneider
- Use correct CI variable name for GitHub mirror PAT ([05c7415c](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/05c7415c4804bf92d334e4251bccccf493209731)) - Timothy Schneider
- Runner token heredoc bug, add SMTP section and screen tips ([56aeea1c](https://gitlab.flarelylegal.com/flarely-legal/gitlab-self-hosted/-/commit/56aeea1cba1d8365ae603012186de3446a2f0fc3)) - Timothy Schneider
