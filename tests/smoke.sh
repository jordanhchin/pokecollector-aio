#!/bin/bash
set -Eeuo pipefail
image="${1:-pokecollector-aio:test}"
name="pokecollector-aio-smoke-$RANDOM"
config=$(mktemp -d)

cleanup() {
  result=$?
  if (( result != 0 )) && docker inspect "$name" >/dev/null 2>&1; then
    echo >&2 "--- container logs after smoke-test failure ---"
    docker logs "$name" >&2 || true
    docker inspect -f 'state={{json .State}}' "$name" >&2 || true
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  # PostgreSQL files belong to its container UID. Remove them as container root
  # rather than assuming that the host CI/Unraid user owns the bind mount.
  if ! docker run --rm --entrypoint /bin/bash -v "$config:/config" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$image" \
    -c 'find /config -mindepth 1 -delete && chown "$HOST_UID:$HOST_GID" /config && chmod 0700 /config' \
    >/dev/null 2>&1; then
    echo >&2 "failed to clean PostgreSQL-owned smoke-test files"
    (( result != 0 )) || result=1
  fi
  if ! rmdir "$config"; then
    echo >&2 "failed to remove smoke-test configuration directory: $config"
    (( result != 0 )) || result=1
  fi
  exit "$result"
}
trap cleanup EXIT

wait_healthy() {
  local status running
  for _ in $(seq 1 120); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")
    [[ "$status" == healthy ]] && return 0
    running=$(docker inspect -f '{{.State.Running}}' "$name")
    [[ "$running" == true ]] || { echo >&2 "container exited while waiting for health"; return 1; }
    sleep 2
  done
  echo >&2 "container did not become healthy (last health status: ${status:-missing})"
  return 1
}

docker run -d --name "$name" -p 127.0.0.1::3000 -v "$config:/config" \
  -e POSTGRES_PASSWORD=smoke-test-password -e ADMIN_PASSWORD=smoke-test-admin "$image" >/dev/null
wait_healthy
port=$(docker port "$name" 3000/tcp | sed 's/.*://')

# Both user-facing checks go through the sole externally published nginx port.
curl -fsS "http://127.0.0.1:$port/api/health" | grep -q '"status"'
curl -fsS "http://127.0.0.1:$port/" | grep -qi '<html'

system_id=$(docker exec "$name" psql -U pokemon -d pokemon_tcg -Atqc \
  "SELECT system_identifier FROM pg_control_system()")
test -n "$system_id"
docker exec "$name" test -s /config/auth/jwt_secret.key
docker exec "$name" test -d /config/backups
docker exec "$name" test "$(readlink -f /app/backups)" = /config/backups
docker exec "$name" test ! -e /config/postgresql/.first-run
for path in app uploads backups auth scan-traces logs postgresql/data; do
  docker exec "$name" test -d "/config/$path"
done
docker exec "$name" sh -c 'test "$BACKUP_DIR" = /config/backups'
jwt_checksum=$(docker exec "$name" sha256sum /config/auth/jwt_secret.key | awk '{print $1}')
docker exec "$name" touch /config/backups/smoke-persistent-backup.sql

# Restart the exact container and bind mount, proving startup reuses rather than
# initializes the database and retains all authentication/backup paths.
docker stop -t 60 "$name" >/dev/null
docker start "$name" >/dev/null
wait_healthy
test "$(docker exec "$name" psql -U pokemon -d pokemon_tcg -Atqc \
  'SELECT system_identifier FROM pg_control_system()')" = "$system_id"
docker exec "$name" test -s /config/auth/jwt_secret.key
docker exec "$name" test -d /config/backups
docker exec "$name" test "$(readlink -f /app/backups)" = /config/backups
docker exec "$name" test ! -e /config/postgresql/.first-run
test "$(docker exec "$name" sha256sum /config/auth/jwt_secret.key | awk '{print $1}')" = "$jwt_checksum"
docker exec "$name" test -f /config/backups/smoke-persistent-backup.sql
curl -fsS "http://127.0.0.1:$port/api/health" | grep -q '"status"'
curl -fsS "http://127.0.0.1:$port/" | grep -qi '<html'
