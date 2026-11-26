#!/usr/bin/env bash
set -euo pipefail

revision=${1:?Uso: psr-image-smoke.sh SHA_GIT ID_DOCKER}
image_id=${2:?Informe o ID Docker homologado ou registrado no artefato}
[[ "$revision" =~ ^[0-9a-f]{40}$ && "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
image="chatwoot-psr:$revision"
compose_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

test "$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$image")" = "$image_id linux/amd64"
test "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image_id")" = "$revision"
test "$(docker run --pull never --rm --platform linux/amd64 --network none "$image_id" cat /app/.git_sha)" = "$revision"
docker run --pull never --rm --platform linux/amd64 --network none "$image_id" test -s /app/public/vite/.vite/manifest.json

export CHATWOOT_IMAGE_TAG="$revision"
export FRONTEND_URL=https://chatwoot.invalid
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
REDIS_PASSWORD=$(openssl rand -hex 24)
export SECRET_KEY_BASE POSTGRES_PASSWORD REDIS_PASSWORD

project="psr-smoke-$(openssl rand -hex 8)"
compose_file=$(mktemp)
trap 'rm -f -- "$compose_file"' EXIT
git -C "$compose_dir" show "$revision:docker-compose.dokploy.yml" > "$compose_file"
compose=(docker compose --env-file /dev/null --project-directory "$compose_dir" -p "$project"
  -f "$compose_file" -f "$compose_dir/docker/compose.psr-smoke.yml")
trap '"${compose[@]}" down --volumes; rm -f -- "$compose_file"' EXIT

"${compose[@]}" pull postgres redis
if ! "${compose[@]}" up --no-build --pull never --wait --wait-timeout 240 rails sidekiq; then
  "${compose[@]}" logs --tail=100 prepare rails sidekiq
  exit 1
fi

if ! "${compose[@]}" exec -T redis sh -es <<'REDIS_CHECK'
export REDISCLI_AUTH="$REDIS_PASSWORD"
for attempt in $(seq 1 30); do
  if test "$(redis-cli --raw SCARD processes)" -gt 0; then exit 0; fi
  sleep 2
done
exit 1
REDIS_CHECK
then
  "${compose[@]}" logs --tail=100 sidekiq
  exit 1
fi

for service in prepare rails sidekiq; do
  container=$("${compose[@]}" ps -a -q "$service")
  test "$(docker inspect --format '{{.Image}}' "$container")" = "$image_id"
  case "$service" in
    prepare) test "$(docker inspect --format '{{.State.Status}}/{{.State.ExitCode}}' "$container")" = exited/0 ;;
    rails) test "$(docker inspect --format '{{.State.Health.Status}}' "$container")" = healthy ;;
    sidekiq) test "$(docker inspect --format '{{.State.Running}}/{{.RestartCount}}' "$container")" = true/0 ;;
  esac
done
printf 'Smoke aprovado: %s %s linux/amd64\n' "$revision" "$image_id"
