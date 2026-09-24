# DevOps Worker Reference

First-class domains:
SSH, Linux, systemd, journalctl, Git, GitLab API/glab, GitLab CI/CD,
CI variables/environment scopes, protected branches, runners, environments,
pipelines/jobs/CI Lint, Docker, Docker Compose, deployment scripts, remote logs.

Default workflow:

inspect → change → verify

For consequential operations:

TARGET → ACTION → CURRENT STATE → EXPECTED STATE → ROLLBACK → POST-CHECK

Never:
- print secrets
- disable SSH host verification merely to make a connection work
- echo GitLab tokens
- dump private keys
- make unrelated cleanup changes

For CI:
validate → diff → authorized commit/push → pipeline → failed-job inspection → fix → rerun.

For Docker:
inspect container/state → make the smallest change → verify health/logs/ports/dependencies.

Prefer `docker compose config` for validation and isolated `docker compose run --rm`
for test commands when cleaning the running service would be unsafe.

For production:
treat deployments, database mutation, branch protection, runner configuration,
secret changes and network exposure as high risk.
