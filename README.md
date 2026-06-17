# caddy-admin-ui

Local, authenticated Flask UI for conservatively importing, editing, validating,
applying, and rolling back an existing Dockerised Caddy configuration.

<img width="2700" height="1534" alt="image" src="https://github.com/user-attachments/assets/593f1d97-4cf1-4730-aa9a-76fe0b1412fc" />


This project is currently prepared for a private-source, public-container
distribution model:

- the source repository remains private for development
- public users deploy a prebuilt container image
- the public deployment wrapper repo contains only deployment/support files

Phase 1 provides guided reverse-proxy sites, basic auth hash management,
preserved advanced blocks, preview/diff, validation, backup/apply/reload,
rollback, audit events, and Caddy container logs. It does not expose Caddy's
Admin API and does not replace the Caddyfile on startup or import.

## Safety model

- The existing Caddyfile is the source of truth. The SQLite database is only a
  management view/cache plus draft state for guided edits.
- On startup, preview, validation, and manual refresh, the app reads the live
  Caddyfile and reconciles its view from that file.
- Fully understood simple reverse proxy blocks and tokenised path proxy stream
  blocks are imported as managed records.
- Site blocks containing unsupported directives are marked **Advanced /
  unmanaged** and preserved verbatim when candidates are generated.
- The generated candidate is built from managed records plus preserved live
  Caddyfile segments; it is not built from database rows alone.
- If the live Caddyfile changes after the app last read it, validation/apply is
  blocked until an administrator selects **Refresh from Caddyfile**.
- Every candidate is validated inside the `caddy` container before apply.
- Every apply and rollback backs up the current live file first.
- Backup files use timestamped names such as `Caddyfile.backup-20260616-183000`.
- The live file is replaced only after validation succeeds, then Caddy is
  reloaded.
- A validation or backup failure stops the workflow.
- A reload failure is recorded and the previous file remains available on the
  Backups page and on disk.

<img width="2702" height="1504" alt="image" src="https://github.com/user-attachments/assets/04559aee-987c-4964-9d9b-b82570acb182" />

## Deployment

The repository keeps the current working `docker-compose.yml` compatible with
the existing install, and also ships a portable `docker-compose.example.yml`
for a fresh host. That example is intended for the public deployment-only repo
and uses the published image:

`ghcr.io/dougle03/caddy-ui:latest`

For public deployment, use the deployment wrapper files rather than this
private source tree.

The published image supports `linux/amd64` and `linux/arm64`.

Release-worthy changes must bump the app version in `app/version.py`. The
published container image tag must match that app version exactly. Publish a
fixed rollback tag such as `ghcr.io/dougle03/caddy-ui:v2026.06.16` and also
update `ghcr.io/dougle03/caddy-ui:latest` as a convenience tag. Do not invent
a separate container version unrelated to the app version.

For a new host, clone the public deployment repo and run the installer helper
first:

```bash
git clone https://github.com/dougle03/caddy-ui-public.git
cd caddy-ui-public
./scripts/install.sh
```

It checks Docker and Docker Compose, auto-detects the Caddy container and host
mount in the common case, generates `.env`, and starts the stack after a single
confirmation. Use `--manual` only when detection is ambiguous.

`scripts/install.sh` is mainly for first install or deliberate reconfiguration.
Existing users normally do not need to run it for a routine update.

## Installer permission requirements

The installer is intended to be run by the person who administers the
Docker/Caddy host. In practice that means a sudo-capable user, or a user
already configured for Docker and Caddy administration.

The user running the installer must be able to:

- use Docker and Docker Compose
- create or manage the `caddy-ui` install directory
- read and write the host Caddyfile directory
- grant ACL access to container UID `10001` where required
- restart or reload the existing Caddy container

This is appropriate because `caddy-ui` edits and reloads Caddy and also uses
the Docker socket to inspect and manage the existing Caddy container.

The installer must not use `chmod 777`. If it cannot safely apply the required
permissions itself, it should print the exact `sudo` command that the host
administrator needs to run. Do not treat this as a tool for completely
unprivileged users.

The public deployment wrapper repo should point at
`ghcr.io/dougle03/caddy-ui:latest`.

## Public Deployment Wrapper

The public deployment-only repo should contain only deployment/support files,
not the Flask source, tests, private notes, or local working files.

See [PUBLIC_DEPLOYMENT_FILES.md](PUBLIC_DEPLOYMENT_FILES.md) for the exact
allowlist.

If you want to prepare a clean local export folder from this private repo
without pushing anything, run:

```bash
./scripts/prepare-public-deploy.sh
```

It copies only the allowlisted files into `./public-deploy/` and prints every
file copied.

1. Create local settings:

   ```bash
   cp .env.example .env
   python3 -c "import secrets; print(secrets.token_urlsafe(48))"
   stat -c '%g' /var/run/docker.sock
   ```

2. Put the generated secret, trusted subnet, host Caddy directory, and Docker
   socket group ID in `.env`.

3. Confirm that `${CADDY_HOST_DIR}/Caddyfile` is the host file mounted in the
   existing `caddy` container as `/etc/caddy/Caddyfile`.

4. Build and start:

   ```bash
   docker compose config
   docker compose up -d --build
   docker compose logs -f caddy-admin-ui
   ```

5. Open `http://SERVER_LAN_IP:5059`, create the first administrator, and review
   the detected Caddyfile. Import does not modify the live file.

For a fresh host, `APP_LISTEN_IP=0.0.0.0` is acceptable if
`APP_ALLOWED_SUBNETS` is restricted correctly. The public installer uses a safe
default that includes local, Docker bridge, and common private/VPN ranges; you
can tighten it later. Login is required for all application pages.

## Updating an existing installation

For a normal update, keep your existing `docker-compose.yml`, `.env`, named
volume, Caddyfile mount, and ACLs.

Do not normally run `scripts/install.sh` for a routine update. Use it only for
first install or when you deliberately want to reconfigure the host-specific
settings.

Typical update commands:

- Image-based deployment:

  ```bash
  docker compose pull && docker compose up -d
  ```

- Local build deployment:

  ```bash
  docker compose up -d --build
  ```

For private/local development in this source repo, use:

```bash
docker compose up -d --build
```

After installing or updating, sign in to the UI and check the
**Diagnostics** page.

## First-run storage and ownership

- The container now prepares `/data`, `/data/backups`, and `/data/working`
  during startup before dropping to the application UID.
- The runtime UID/GID is `10001:10001`.
- The container entrypoint preserves supplementary groups when dropping
  privileges so the app process keeps Docker socket group access when
  `group_add` is used in Compose.
- See [Installer permission requirements](#installer-permission-requirements)
  for who should run the installer and which host permissions are expected.
- If the live Caddyfile bind mount is owned by another user, grant that UID
  write access with a normal group/ACL rule instead of `chmod 777`.
- The app never needs world-writable permissions on its database or backup
  paths.

## Diagnostics

Open **Diagnostics** after login to confirm:

- database, backup, and working paths
- live Caddyfile read/write status
- Docker socket access
- Docker GID seen inside the container
- effective supplementary groups for the running app process
- visible mounts such as `/data` and `/managed-caddy`
- Caddy container lookup and the configured in-container Caddyfile path

The page also includes a copyable report for troubleshooting.

## Routine workflow

1. Open **Sites** and select **Refresh from Caddyfile** before editing if the
   banner reports an external change.
2. Edit or create a simple managed site in **Sites**. Saving changes only the SQLite draft.
   TLS settings support automatic HTTPS, manual certificate and key paths as
   seen inside the Caddy container, internal certificates, an ACME email, and
   preserved advanced `tls` blocks.
3. Inspect **Advanced / unmanaged** site blocks. They are view-only in the
   normal form and are preserved during saves.
4. Open **Preview** and review the complete candidate and diff.
5. Select **Validate only**.
6. After successful validation and review, select **Apply and reload**.
7. Use **Backups** to restore an earlier file. Rollback itself first backs up
   the current file, validates the selected backup, replaces the live file, and
   reloads Caddy.

The hash tool runs `caddy hash-password` inside the existing container. The
plaintext password is neither stored nor logged. Add only its resulting hash to
a site's authentication users.

## Tokenised Path Proxies

Tokenised Path Proxies manage site blocks that use `handle`, `rewrite`, and
`reverse_proxy` to expose a hard-to-guess public path for one internal path.
This is useful for cases such as an Icecast stream where
`https://streams.example.com/long-secret-radio1` should proxy to
`http://10.10.50.116:8000/radio1.mp3`.

This is not authentication. Anyone with the full URL can still access it.

## Environment

| Variable | Purpose |
|---|---|
| `APP_LISTEN_IP` | Host LAN address used for Docker port publishing |
| `APP_PORT` | Host port published for the UI, default `5059` |
| `APP_SECRET_KEY` | Flask session signing secret; required |
| `APP_ALLOWED_SUBNETS` | Comma-separated IP networks allowed to use the UI |
| `APP_SESSION_SECURE` | Set `true` when the browser uses HTTPS |
| `APP_DB_PATH` | SQLite path inside the app container |
| `APP_BACKUP_DIR` | Durable backup directory |
| `APP_ACCESS_LOG_RETENTION_DAYS` | Parsed access-log retention, default 14 days |
| `APP_ACCESS_LOG_INGEST_TAIL` | Recent Caddy log lines inspected for JSON access entries |
| `CADDY_HOST_DIR` | Host directory mounted into the app as `/managed-caddy` |
| `CADDY_CONTAINER_NAME` | Existing container, default `caddy` |
| `CADDYFILE_APP_PATH` | Bind-mounted live file as seen by this app |
| `CADDYFILE_CONTAINER_PATH` | Same live file as seen inside Caddy |
| `DOCKER_GID` | Host group ID that owns `/var/run/docker.sock` |

## Docker socket risk

The Docker socket grants extremely broad host control. It is mounted in phase 1
because validation, reload, logs, status, and hash generation all target the
existing independently managed Caddy container. Keep this UI LAN-restricted and
authenticated. See [Installer permission requirements](#installer-permission-requirements)
and [SECURITY.md](SECURITY.md).

## Development and tests

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
pytest -q
```

Tests use temporary Caddyfiles and fake Docker command results. They do not
modify `/home/kayp/docker/caddy`.

## Troubleshooting

- `403 Forbidden`: check `APP_ALLOWED_SUBNETS` and whether you are reaching the
  app from the expected LAN address.
- Caddyfile read-only or missing: open **Diagnostics** and check the reported
  `Caddyfile app path`. Fix the host bind mount or host ACLs for UID `10001`.
- Docker socket errors: confirm `/var/run/docker.sock` is mounted and
  `DOCKER_GID` matches `stat -c '%g' /var/run/docker.sock`. If the socket GID
  is correct but Docker access still fails, check **Diagnostics** and confirm
  the running process supplementary groups include that same GID.
- Site save fails on the upstream field: the internal upstream URL must include
  an explicit port such as `http://127.0.0.1:80` or
  `http://192.168.1.50:8123`.

## Manual recovery

The GUI is not required for recovery:

```bash
docker stop caddy-admin-ui

# Locate the named volume and list backups, or copy one out:
docker volume inspect caddy-ui_caddy_admin_data
docker run --rm -v caddy-ui_caddy_admin_data:/data alpine ls -lah /data/backups

# Copy the selected backup to the host bind mount.
docker run --rm \
  -v caddy-ui_caddy_admin_data:/data:ro \
  -v /home/kayp/docker/caddy:/managed-caddy \
  alpine cp /data/backups/Caddyfile.backup-TIMESTAMP /managed-caddy/Caddyfile

docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

If the Compose project name differs, use `docker volume ls` to find the
`caddy_admin_data` volume. Always validate before reloading.
