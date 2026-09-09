# PokéCollector AIO

An **unofficial**, all-in-one Docker packaging of [Git-Romer/pokecollector](https://github.com/Git-Romer/pokecollector). It combines PostgreSQL 18, the FastAPI API, and the React application served by nginx in one image. This repository and the bundled upstream application are distributed under the AGPL-3.0; it is not affiliated with or endorsed by the upstream maintainers.

The image pins upstream **v1.41.0** at commit `dcff367f983b35688576a94b3ef79d20f3041cb1`; builds never follow a moving branch. Only the nginx web port is exposed. PostgreSQL and FastAPI listen on loopback inside the container.

The current image supports **AMD64/x86-64 Unraid systems only**. ARM64 images are not currently published.

## Install

```bash
docker run -d --name pokecollector \
  -p 3000:3000 \
  -v /path/to/pokecollector:/config \
  -e POSTGRES_PASSWORD='use-a-long-random-password' \
  -e ADMIN_USERNAME=admin \
  -e ADMIN_PASSWORD='use-another-long-password' \
  --restart unless-stopped \
  ghcr.io/jordanhchin/pokecollector-aio:latest
```

Open `http://SERVER:3000`. `POSTGRES_PASSWORD` is mandatory when `/config/postgresql/data` is new. Keep it unchanged afterward. `ADMIN_PASSWORD` bootstraps the application administrator; leaving `JWT_SECRET_KEY` empty lets PokéCollector generate and persist it under `/config/auth`.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `WEB_PORT` | `3000` | Internal nginx listen port (normally leave unchanged) |
| `POSTGRES_USER` / `POSTGRES_DB` | `pokemon` / `pokemon_tcg` | Internal database identity; do not change after initialization |
| `POSTGRES_PASSWORD` | *(required first run)* | Internal database password |
| `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `USER_MODE` | `admin`, empty, empty | Upstream authentication bootstrap/recovery |
| `JWT_SECRET_KEY` | generated | Optional fixed JWT signing secret |
| `PUBLIC_MODE` | `false` | Frontend indexing mode (build-time option, not runtime) |
| `CORS_ORIGINS` | empty | Comma-separated additional origins |
| `TCGDEX_SYNC_LANGUAGES` | `en,de` | Catalogue languages |
| `GEMINI_API_KEY`, `GEMINI_MODEL` | empty, `gemini-flash-latest` | Gemini scanner settings |
| `OPENAI_SCANNER_ENABLED`, `OPENAI_BASE_URL`, `OPENAI_MODEL` | `false`, empty, upstream default | OpenAI-compatible scanner settings |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | empty | Optional notifications |
| `PRE_UPGRADE_BACKUP_ENABLED`, `PRE_UPGRADE_BACKUP_REQUIRED`, `PRE_UPGRADE_BACKUP_KEEP` | `true`, `true`, `10` | Migration safety backups |

All durable state is below the single `/config` mount: PostgreSQL uses `postgresql/data`; Pokédex images use `app/pokedex-images`; scanner uploads use `uploads`; both pre-upgrade and interactive SQL backups use `backups`; the generated JWT key uses `auth/jwt_secret.key`; opted-in scanner diagnostics use `scan-traces`; and debug output uses `logs`. `SCAN_TRACE_STORAGE_DIR` always points at the persistent trace location so the application can remove previously collected traces, while trace collection remains off unless `SCAN_TRACE_DIR=/config/scan-traces` is explicitly set. No generic “other” directory or unused application-data environment variable is created.

Startup makes restrictive bind mounts traversable by the unprivileged PostgreSQL process without making the database directory public, initializes PostgreSQL only when `PG_VERSION` is absent, rejects incompatible database major versions, waits for readiness, creates the database once, and then lets the upstream idempotent startup migrations run. Supervisor forwards termination and gives the API time to shut down before PostgreSQL. The upstream interactive backup API has a fixed `/app/backups` path, so the image makes that path a symbolic link to `/config/backups`; the pre-upgrade backup service is configured there directly.

The bundled nginx configuration retains the pinned upstream security headers and Content-Security-Policy, gzip types and threshold, 500 MB server upload limit, 100 MB API upload limit, cache behavior, and API proxy timeouts. Its only intentional deployment changes are listening on the configurable AIO web port and proxying FastAPI over loopback instead of the Compose service hostname.

## Upgrade and image tags

Back up first, pull a chosen tag, remove the old container, and recreate it with the same `/config` mount and environment. Releases publish `latest`, the repository release tag (for example `1.2.0`), major/minor (`1.2`), and major (`1`) for `linux/amd64` only. Prefer a full version tag for reproducibility. `latest` tracks the newest packaging release, not the upstream default branch.

Never downgrade PostgreSQL data or the application without restoring a matching backup. Upstream automatically writes pre-migration SQL dumps in `/config/backups`; startup fails if a required safety backup cannot be made.

## Backup and restore

Stop the container for the simplest consistent full backup, then archive all of `/config`:

```bash
docker stop pokecollector
tar -C /path/to -czf pokecollector-config-$(date +%F).tgz pokecollector
docker start pokecollector
```

To restore, stop/remove the container, move the current config aside, extract the archive to the original path, and recreate the container with the original database variables. For an application SQL backup in `/config/backups`, start with a clean compatible PostgreSQL 18 data directory, copy the dump into `backups`, then run:

```bash
docker exec -i pokecollector psql -U pokemon -d pokemon_tcg < /path/to/backup.sql
```

Stop application traffic during restore. Preserve uploaded files and authentication data as well as SQL; a SQL dump alone is not a complete installation backup.

## Health and troubleshooting

The Docker health check requires `pg_isready`, `GET /api/health`, and the nginx root page to succeed. Inspect it and logs with:

```bash
docker inspect --format '{{json .State.Health}}' pokecollector
docker logs --tail 200 pokecollector
docker exec pokecollector aio-healthcheck
```

Common issues:

* **First run exits:** set a nonempty `POSTGRES_PASSWORD` and ensure `/config` is writable.
* **Database version error:** do not delete data; migrate/restore it into PostgreSQL 18.
* **Unhealthy during initial boot:** migrations and catalogue initialization can exceed the 90-second grace period on slow storage; examine logs.
* **Login/JWT changes after recreation:** ensure the entire `/config`, especially `/config/auth`, is persistent.
* **Uploads or backups missing:** confirm the host mapping targets `/config`, not an individual internal application path.

## Unraid and Tailscale

Install using [`unraid/pokecollector-aio.xml`](unraid/pokecollector-aio.xml), map `/config` to an appdata directory, set strong database/admin passwords, and publish container port `3000` only. Do not publish ports 5432 or 8000.

On Unraid 7, the template declares `/config/.tailscale_state` as its Tailscale state directory. Enable **Use Tailscale** in the container settings to give PokéCollector its own Tailnet device identity and MagicDNS hostname, then select the desired Tailscale network access mode. Keep container port 3000 as the web service and never expose its internal database or API ports. Apply Tailscale ACLs/grants to that device identity.

Optionally configure **Tailscale Serve** in Unraid's container integration to publish port 3000 as HTTPS on the container's Tailnet hostname. Use the resulting HTTPS origin in `CORS_ORIGINS` if cross-origin access requires it. As an alternative, leave **Use Tailscale** disabled, keep bridge networking, and reach the published host port at `http://UNRAID-TAILSCALE-IP:HOST_PORT`; this shares the Unraid host's Tailnet identity rather than giving the application its own identity.

## Development

```bash
bash tests/static.sh
docker build -t pokecollector-aio:test .
bash tests/smoke.sh pokecollector-aio:test
```

See [`UPSTREAM.md`](UPSTREAM.md) for the upstream assessment and pin update procedure.
