#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV="${MIX_ENV:-dev}"
export PORT="${PORT:-4000}"
export PHX_HOST="${PHX_HOST:-localhost}"
export DATABASE_URL="${DATABASE_URL:-ecto://postgres:postgres@prod-db/quickstart_dev}"
export APP_NODE_NAME="${APP_NODE_NAME:-prod@prod}"
export REVERB_ERLANG_COOKIE="${REVERB_ERLANG_COOKIE:-reverb_quickstart_cookie}"
export QUICKSTART_APP_NAME="${QUICKSTART_APP_NAME:?missing QUICKSTART_APP_NAME}"
export QUICKSTART_APP_MODULE="${QUICKSTART_APP_MODULE:?missing QUICKSTART_APP_MODULE}"
export REVERB_PUBSUB_NAME="${REVERB_PUBSUB_NAME:?missing REVERB_PUBSUB_NAME}"
export REVERB_TOPIC_HASH="${REVERB_TOPIC_HASH:?missing REVERB_TOPIC_HASH}"

app_root="/workspace/app"
database_host="$(printf '%s\n' "$DATABASE_URL" | sed -E 's#^[a-z]+://[^@]+@([^:/]+).*#\1#')"
database_port="$(printf '%s\n' "$DATABASE_URL" | sed -nE 's#^[a-z]+://[^@]+@[^:/]+:([0-9]+).*#\1#p')"
database_port="${database_port:-5432}"

until pg_isready -h "$database_host" -p "$database_port" -U postgres >/dev/null 2>&1; do
  echo "waiting for postgres at ${database_host}:${database_port}"
  sleep 1
done

if [[ ! -f "$app_root/mix.exs" ]]; then
  rm -rf "$app_root"
  mkdir -p /workspace

  mix archive.install hex phx_new 1.7.14 --force
  mix phx.new "$app_root" \
    --app "$QUICKSTART_APP_NAME" \
    --module "$QUICKSTART_APP_MODULE" \
    --database postgres \
    --no-dashboard \
    --no-mailer \
    --no-install

  cd "$app_root"

  if ! grep -q '{:reverb, path: "../.reverb-src"}' mix.exs; then
    sed -i '/{:postgrex, ">= 0.0.0"}/a\      {:reverb, path: "../.reverb-src"},' mix.exs
  fi

  mix deps.get
  mix reverb.install --patch-config --force --pubsub "$REVERB_PUBSUB_NAME" --topic-hash "$REVERB_TOPIC_HASH"
  rm -f .env.reverb .reverb.cookie.example docker-compose.reverb.yml README.reverb.md
  sed -i 's/logger_handler: false/logger_handler: true/' config/reverb.exs

  /workspace/docker/inject-captain.sh "$app_root"

  git init >/dev/null
  git branch -M main >/dev/null 2>&1 || true
  git config user.name "Reverb Quickstart"
  git config user.email "quickstart@reverb.invalid"
  git add -A
  git commit -m "Initial quickstart app" >/dev/null
fi

cd "$app_root"
mix deps.get
mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate
/workspace/docker/inject-captain.sh "$app_root"

exec elixir --name "$APP_NODE_NAME" --cookie "$REVERB_ERLANG_COOKIE" -S mix phx.server
