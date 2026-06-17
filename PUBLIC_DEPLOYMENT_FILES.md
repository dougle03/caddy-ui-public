# Public Deployment Files

These files are intended to be copied from the private source repository into
the public deployment-only repository.

Allowlist:

- `README.md`
- `docker-compose.example.yml`
- `.env.example`
- `scripts/install.sh`
- `PUBLIC_DEPLOYMENT_FILES.md`

Optional helper:

- `scripts/prepare-public-deploy.sh`

Do not copy:

- `app/`
- `tests/`
- local notes, prompts, roadmap files, or private working documents
- runtime databases, logs, backups, or uploaded files
- private local deployment files beyond the allowlist above
