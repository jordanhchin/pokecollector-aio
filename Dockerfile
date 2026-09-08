# syntax=docker/dockerfile:1.7
ARG UPSTREAM_REF=dcff367f983b35688576a94b3ef79d20f3041cb1

FROM alpine:3.22 AS source
ARG UPSTREAM_REF
RUN apk add --no-cache curl tar \
 && mkdir /src \
 && curl -fsSL "https://codeload.github.com/Git-Romer/pokecollector/tar.gz/${UPSTREAM_REF}" \
    | tar -xz --strip-components=1 -C /src

FROM node:20-alpine AS frontend
ARG PUBLIC_MODE=false
COPY --from=source /src /src
WORKDIR /src/frontend
RUN npm ci \
 && if [ "$PUBLIC_MODE" = true ]; then cp public/robots-allow.txt public/robots.txt; \
    else cp public/robots-block.txt public/robots.txt; fi \
 && npm run build

FROM python:3.11-slim-bookworm AS python-deps
COPY --from=source /src/backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --prefix=/install -r /tmp/requirements.txt

FROM postgres:18-bookworm
ARG UPSTREAM_REF
ARG UPSTREAM_VERSION=1.41.0
LABEL org.opencontainers.image.source="https://github.com/jordanhchin/pokecollector-aio" \
      org.opencontainers.image.licenses="AGPL-3.0" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      io.pokecollector.upstream-revision="${UPSTREAM_REF}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 nginx supervisor curl ca-certificates \
 && ln -s /usr/bin/python3 /usr/local/bin/python \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default
COPY --from=python-deps /install /usr/local
COPY --from=source /src/backend /opt/pokecollector/backend
COPY --from=source /src/VERSION /opt/pokecollector/VERSION
COPY --from=frontend /src/frontend/dist /usr/share/nginx/html
COPY rootfs/ /
RUN chmod +x /usr/local/bin/aio-entrypoint /usr/local/bin/start-backend /usr/local/bin/aio-healthcheck \
 && mkdir -p /config /run/postgresql /run/nginx /var/log/supervisor

ENV WEB_PORT=3000 POSTGRES_USER=pokemon POSTGRES_DB=pokemon_tcg \
    DATA_DIR=/config/app AUTH_DATA_DIR=/config/auth BACKUP_DIR=/config/backups \
    SCAN_UPLOAD_DIR=/config/uploads SCAN_TRACE_STORAGE_DIR=/config/scan-traces \
    POKEDEX_IMAGE_CACHE_DIR=/config/app/pokedex-images \
    DEBUG_LOG_PATH=/config/logs/pokecollector-debug.log \
    PRE_UPGRADE_BACKUP_ENABLED=true PRE_UPGRADE_BACKUP_REQUIRED=true PRE_UPGRADE_BACKUP_KEEP=10 \
    TCGDEX_SYNC_LANGUAGES=en,de PUBLIC_MODE=false
VOLUME ["/config"]
EXPOSE 3000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 CMD ["aio-healthcheck"]
ENTRYPOINT ["aio-entrypoint"]
