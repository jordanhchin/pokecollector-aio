# Upstream assessment and update policy

Inspected upstream `Git-Romer/pokecollector` at commit `dcff367f983b35688576a94b3ef79d20f3041cb1` (version 1.41.0).

* Its Compose stack uses PostgreSQL 18 Alpine, Python 3.11/FastAPI on port 8000, and a Node-built React frontend served by nginx on port 80.
* Compose checks PostgreSQL with `pg_isready`; FastAPI provides `GET /api/health`. The upstream frontend has no health check, so AIO tests nginx directly.
* `backend.database.init_db()` creates tables and runs idempotent PostgreSQL schema migrations during FastAPI lifespan startup. The pre-upgrade service produces `pg_dump` backups before migrations on version changes.
* Durable upstream paths are backups, auth/JWT data, Pokédex images, scan uploads, scan traces, and debug logs. AIO redirects each beneath `/config` and stores PostgreSQL there too.
* Upstream is AGPL-3.0. The unchanged license is carried in this packaging repository.

To update, select an immutable reviewed upstream commit, change `UPSTREAM_REF` and `UPSTREAM_VERSION` in `Dockerfile`, update this document and README, then build and run the smoke test. Review upstream Compose, Dockerfiles, `.env.example`, migrations, dependencies, storage constants, nginx configuration, and license on every update. Never substitute a branch name for the commit SHA.
