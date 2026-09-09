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

check() {
  local name=$1
  shift
  printf '[check] %s ... ' "$name"
  if "$@"; then
    echo 'ok'
  else
    echo 'FAILED' >&2
    return 1
  fi
}

check_equal() {
  local name=$1 actual=$2 expected=$3
  printf '[check] %s ... ' "$name"
  if [[ "$actual" == "$expected" ]]; then
    echo 'ok'
  else
    printf 'FAILED (expected %q, got %q)\n' "$expected" "$actual" >&2
    return 1
  fi
}

check_contains() {
  local name=$1 content=$2 needle=$3
  printf '[check] %s ... ' "$name"
  if grep -Fqi -- "$needle" <<<"$content"; then
    echo 'ok'
  else
    printf 'FAILED (response did not contain %q)\n' "$needle" >&2
    return 1
  fi
}

fetch_response() {
  local name=$1 destination=$2 url=$3 body
  printf '[check] %s ... ' "$name"
  if body=$(curl -fsS "$url"); then
    printf -v "$destination" '%s' "$body"
    echo 'ok'
  else
    echo 'FAILED' >&2
    return 1
  fi
}

wait_healthy() {
  local phase=$1 status running
  printf '[check] %s ... ' "$phase"
  for _ in $(seq 1 120); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")
    if [[ "$status" == healthy ]]; then
      echo 'ok'
      return 0
    fi
    running=$(docker inspect -f '{{.State.Running}}' "$name")
    if [[ "$running" != true ]]; then
      echo 'FAILED (container exited)' >&2
      return 1
    fi
    sleep 2
  done
  echo "FAILED (last health status: ${status:-missing})" >&2
  return 1
}

echo '[phase] initial startup'
docker run -d --name "$name" -p 127.0.0.1::3000 -v "$config:/config" \
  -e POSTGRES_PASSWORD=smoke-test-password -e ADMIN_PASSWORD=smoke-test-admin "$image" >/dev/null
wait_healthy 'initial container health'
port=$(docker port "$name" 3000/tcp | sed 's/.*://')
check 'published nginx port discovered' test -n "$port"

# Capture responses before inspecting them: piping curl into grep -q under
# pipefail lets grep close early and makes curl report SIGPIPE/error 23.
fetch_response 'fetch external nginx /api/health' health_response "http://127.0.0.1:$port/api/health"
check_contains 'external nginx /api/health response' "$health_response" '"status"'
fetch_response 'fetch external nginx frontend' frontend_response "http://127.0.0.1:$port/"
check_contains 'external nginx frontend response' "$frontend_response" '<html'

system_id=$(docker exec "$name" psql -U pokemon -d pokemon_tcg -Atqc \
  "SELECT system_identifier FROM pg_control_system()")
check 'PostgreSQL system identifier recorded' test -n "$system_id"
check 'JWT key created under /config' docker exec "$name" test -s /config/auth/jwt_secret.key
check 'backup directory created under /config' docker exec "$name" test -d /config/backups
backup_target=$(docker exec "$name" readlink -f /app/backups)
check_equal 'interactive backup mapping' "$backup_target" /config/backups
check 'first-run marker removed' docker exec "$name" test ! -e /config/postgresql/.first-run
for path in app uploads backups auth scan-traces logs postgresql/data; do
  check "persistent directory /config/$path" docker exec "$name" test -d "/config/$path"
done
check 'pre-upgrade backup environment mapping' docker exec "$name" sh -c 'test "$BACKUP_DIR" = /config/backups'
jwt_checksum=$(docker exec "$name" sha256sum /config/auth/jwt_secret.key | awk '{print $1}')
check 'JWT checksum recorded' test -n "$jwt_checksum"
check 'backup persistence sentinel created' docker exec "$name" touch /config/backups/smoke-persistent-backup.sql

# Restart the exact container and bind mount, proving startup reuses rather than
# initializes the database and retains all authentication/backup paths.
echo '[phase] same-container restart'
check 'container stops gracefully' docker stop -t 60 "$name"
check 'same container restarts' docker start "$name"
wait_healthy 'restarted container health'
restarted_system_id=$(docker exec "$name" psql -U pokemon -d pokemon_tcg -Atqc \
  'SELECT system_identifier FROM pg_control_system()')
check_equal 'PostgreSQL system identifier persisted' "$restarted_system_id" "$system_id"
check 'JWT key remains under /config' docker exec "$name" test -s /config/auth/jwt_secret.key
check 'backup directory remains under /config' docker exec "$name" test -d /config/backups
restarted_backup_target=$(docker exec "$name" readlink -f /app/backups)
check_equal 'interactive backup mapping after restart' "$restarted_backup_target" /config/backups
check 'first-run marker stays absent' docker exec "$name" test ! -e /config/postgresql/.first-run
restarted_jwt_checksum=$(docker exec "$name" sha256sum /config/auth/jwt_secret.key | awk '{print $1}')
check_equal 'JWT key persisted unchanged' "$restarted_jwt_checksum" "$jwt_checksum"
check 'backup sentinel persisted' docker exec "$name" test -f /config/backups/smoke-persistent-backup.sql
fetch_response 'fetch external nginx /api/health after restart' health_response "http://127.0.0.1:$port/api/health"
check_contains 'external nginx /api/health after restart' "$health_response" '"status"'
fetch_response 'fetch external nginx frontend after restart' frontend_response "http://127.0.0.1:$port/"
check_contains 'external nginx frontend after restart' "$frontend_response" '<html'

echo '[result] all smoke checks passed'
