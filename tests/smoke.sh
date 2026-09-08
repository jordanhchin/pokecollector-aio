#!/bin/bash
set -Eeuo pipefail
image="${1:-pokecollector-aio:test}"
name="pokecollector-aio-smoke-$RANDOM"
config=$(mktemp -d)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$config"; }
trap cleanup EXIT
docker run -d --name "$name" -p 127.0.0.1::3000 -v "$config:/config" \
  -e POSTGRES_PASSWORD=smoke-test-password -e ADMIN_PASSWORD=smoke-test-admin "$image" >/dev/null
for _ in $(seq 1 120); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")
  [[ "$status" == healthy ]] && break
  [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == true ]] || { docker logs "$name"; exit 1; }
  sleep 2
done
[[ "${status:-}" == healthy ]] || { docker logs "$name"; exit 1; }
docker exec "$name" pg_isready -h 127.0.0.1 -U pokemon -d pokemon_tcg
docker exec "$name" curl -fsS http://127.0.0.1:8000/api/health >/dev/null
port=$(docker port "$name" 3000/tcp | sed 's/.*://')
curl -fsS "http://127.0.0.1:$port/" | grep -qi '<html'
docker stop -t 60 "$name" >/dev/null
