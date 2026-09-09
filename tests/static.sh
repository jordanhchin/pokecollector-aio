#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
test -s LICENSE
grep -q '^ARG UPSTREAM_REF=[0-9a-f]\{40\}$' Dockerfile
grep -q 'VOLUME \["/config"\]' Dockerfile
grep -q 'EXPOSE 3000' Dockerfile
test "$(grep -c '^EXPOSE ' Dockerfile)" -eq 1
grep -q 'JWT_SECRET_FILE=/config/auth/jwt_secret.key' Dockerfile
grep -q 'ln -s /config/backups /app/backups' Dockerfile
! grep -q 'AUTH_DATA_DIR\|/config/other' Dockerfile rootfs/usr/local/bin/aio-entrypoint
grep -q '<TailscaleStateDir>/config/.tailscale_state</TailscaleStateDir>' unraid/pokecollector-aio.xml
grep -q 'platforms: linux/amd64$' .github/workflows/image.yml
! grep -q 'setup-qemu-action\|linux/arm64' .github/workflows/image.yml
grep -q 'AMD64/x86-64 Unraid systems only' README.md
grep -q 'Content-Security-Policy' rootfs/etc/nginx/conf.d/default.conf
grep -q 'proxy_pass http://127.0.0.1:8000' rootfs/etc/nginx/conf.d/default.conf
grep -q '^command=postgres -D /config/postgresql/data$' rootfs/etc/supervisor/supervisord.conf
! grep -q '/usr/local/bin/postgres' rootfs/etc/supervisor/supervisord.conf
test "$(grep -c -- '--username="$POSTGRES_USER"' rootfs/usr/local/bin/start-backend)" -eq 2
! grep -Eq 'runuser -u postgres -- psql -|runuser -u postgres -- createdb -O' rootfs/usr/local/bin/start-backend
grep -q '^RUN python3 -m uvicorn --version$' Dockerfile
grep -q 'COPY --from=python-deps /install /usr/local/lib/python3.11/dist-packages' Dockerfile
grep -q '^exec python3 -m uvicorn main:app ' rootfs/usr/local/bin/start-backend
! grep -q 'ln -s /usr/bin/python3 /usr/local/bin/python' Dockerfile
test "$(grep -c 'docker port "\$name" 3000/tcp' tests/smoke.sh)" -eq 2
bash -n rootfs/usr/local/bin/aio-entrypoint rootfs/usr/local/bin/start-backend
sh -n rootfs/usr/local/bin/aio-healthcheck
python3 - <<'PY'
import xml.etree.ElementTree as ET
ET.parse('unraid/pokecollector-aio.xml')
PY
