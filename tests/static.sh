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
grep -q 'Content-Security-Policy' rootfs/etc/nginx/conf.d/default.conf
grep -q 'proxy_pass http://127.0.0.1:8000' rootfs/etc/nginx/conf.d/default.conf
bash -n rootfs/usr/local/bin/aio-entrypoint rootfs/usr/local/bin/start-backend
sh -n rootfs/usr/local/bin/aio-healthcheck
python3 - <<'PY'
import xml.etree.ElementTree as ET
ET.parse('unraid/pokecollector-aio.xml')
PY
