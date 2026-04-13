#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV="${MIX_ENV:-dev}"
export PORT="${PORT:-4000}"
export PHX_HOST="${PHX_HOST:-localhost}"
export DATABASE_URL="${DATABASE_URL:-ecto://postgres:postgres@prod-db/quickstart_dev}"
export APP_NODE_NAME="${APP_NODE_NAME:-prod}"
export APP_USE_SHORTNAME="${APP_USE_SHORTNAME:-true}"
export REVERB_ERLANG_COOKIE="${REVERB_ERLANG_COOKIE:-reverb_quickstart_cookie}"
export QUICKSTART_APP_NAME="${QUICKSTART_APP_NAME:?missing QUICKSTART_APP_NAME}"
export QUICKSTART_APP_MODULE="${QUICKSTART_APP_MODULE:?missing QUICKSTART_APP_MODULE}"
export REVERB_PUBSUB_NAME="${REVERB_PUBSUB_NAME:?missing REVERB_PUBSUB_NAME}"
export REVERB_TOPIC_HASH="${REVERB_TOPIC_HASH:?missing REVERB_TOPIC_HASH}"
export INITIAL_ADMIN_EMAIL="${INITIAL_ADMIN_EMAIL:?missing INITIAL_ADMIN_EMAIL}"
export INITIAL_ADMIN_PASSWORD="${INITIAL_ADMIN_PASSWORD:?missing INITIAL_ADMIN_PASSWORD}"

node_name_flag="--name"

if [[ "$APP_USE_SHORTNAME" == "true" ]]; then
  node_name_flag="--sname"
fi

app_root="/workspace/app"
database_host="$(printf '%s\n' "$DATABASE_URL" | sed -E 's#^[a-z]+://[^@]+@([^:/]+).*#\1#')"
database_port="$(printf '%s\n' "$DATABASE_URL" | sed -nE 's#^[a-z]+://[^@]+@[^:/]+:([0-9]+).*#\1#p')"
database_port="${database_port:-5432}"
database_name="$(printf '%s\n' "$DATABASE_URL" | sed -E 's#.*/([^/?]+)(\?.*)?$#\1#')"

until pg_isready -h "$database_host" -p "$database_port" -U postgres >/dev/null 2>&1; do
  echo "waiting for postgres at ${database_host}:${database_port}"
  sleep 1
done

if [[ ! -f "$app_root/mix.exs" ]]; then
  mix archive.install hex phx_new 1.8.5 --force
  mix archive.install hex igniter_new --force

  mix phx.new "$app_root" \
    --app "$QUICKSTART_APP_NAME" \
    --module "$QUICKSTART_APP_MODULE" \
    --database postgres \
    --no-dashboard \
    --no-mailer \
    --no-install

  cd "$app_root"

  sed -i 's/{127, 0, 0, 1}/{0, 0, 0, 0}/' config/dev.exs
  sed -i "s/hostname: \"localhost\"/hostname: \"$database_host\"/" config/dev.exs
  sed -i -E "s/database: \"[^\"]+\"/database: \"$database_name\"/" config/dev.exs
  perl -0pi -e 's/watchers:\s*\[.*?\n\s*\]/watchers: []/s' config/dev.exs

  if ! grep -q '{:reverb, path: "../.reverb-src"}' mix.exs; then
    sed -i '/{:postgrex, ">= 0.0.0"}/a\      {:reverb, path: "../.reverb-src"},' mix.exs
  fi

  mix deps.get

  if ! grep -q 'ash_authentication_phoenix' mix.exs; then
    mix igniter.install ash,ash_postgres,ash_phoenix --yes --yes-to-deps
    mix igniter.install ash_authentication --auth-strategy password --yes --yes-to-deps
    mix igniter.install ash_authentication_phoenix --yes --yes-to-deps
  fi

  mix deps.get
  mix reverb.install --patch-config --force --pubsub "$REVERB_PUBSUB_NAME" --topic-hash "$REVERB_TOPIC_HASH" --quickstart --captain
  sed -i 's/logger_handler: false/logger_handler: true/' config/reverb.exs

  mix assets.deploy

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
mix run -e "${QUICKSTART_APP_MODULE}.Release.ensure_initial_admin_from_env()"
mix assets.deploy

exec elixir "$node_name_flag" "$APP_NODE_NAME" --cookie "$REVERB_ERLANG_COOKIE" -S mix phx.server
