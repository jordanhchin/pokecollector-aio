#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
test -s LICENSE
grep -q '^ARG UPSTREAM_REF=[0-9a-f]\{40\}$' Dockerfile
grep -q 'VOLUME \["/config"\]' Dockerfile
grep -q 'EXPOSE 3000' Dockerfile
test "$(grep -c '^EXPOSE ' Dockerfile)" -eq 1
bash -n rootfs/usr/local/bin/aio-entrypoint rootfs/usr/local/bin/start-backend
sh -n rootfs/usr/local/bin/aio-healthcheck
python3 - <<'PY'
import xml.etree.ElementTree as ET
ET.parse('unraid/pokecollector-aio.xml')
PY
