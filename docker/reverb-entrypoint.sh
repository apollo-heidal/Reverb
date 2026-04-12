#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV="${MIX_ENV:-prod}"
export REVERB_DATABASE_URL="${REVERB_DATABASE_URL:-ecto://postgres:postgres@reverb-db/reverb_dev}"
export REVERB_NODE_NAME="${REVERB_NODE_NAME:-reverb@reverb}"
export REVERB_USE_SHORTNAME="${REVERB_USE_SHORTNAME:-false}"
export REVERB_ERLANG_COOKIE="${REVERB_ERLANG_COOKIE:-reverb_cookie}"
export REVERB_WORKSPACE_ROOT="${REVERB_WORKSPACE_ROOT:-/workspaces}"
export REVERB_WORKSPACE_REPO_ROOT="${REVERB_WORKSPACE_REPO_ROOT:-/sandbox/app}"
export REVERB_WORKSPACE_SOURCE_REF="${REVERB_WORKSPACE_SOURCE_REF:-HEAD}"
export REVERB_PATH="${REVERB_PATH:-/opt/reverb}"
export REVERB_OPENCODE_WEB_ENABLED="${REVERB_OPENCODE_WEB_ENABLED:-false}"
export REVERB_OPENCODE_WEB_HOST="${REVERB_OPENCODE_WEB_HOST:-0.0.0.0}"
export REVERB_OPENCODE_WEB_PORT="${REVERB_OPENCODE_WEB_PORT:-4096}"
export REVERB_OPENCODE_WEB_WORKDIR="${REVERB_OPENCODE_WEB_WORKDIR:-$REVERB_WORKSPACE_REPO_ROOT}"
export REVERB_WORKSPACE_WAIT_TIMEOUT_SECS="${REVERB_WORKSPACE_WAIT_TIMEOUT_SECS:-300}"

node_name_flag="--name"

if [[ "$REVERB_USE_SHORTNAME" == "true" ]]; then
  node_name_flag="--sname"
fi

mkdir -p "$REVERB_WORKSPACE_ROOT"

database_host="$(printf '%s\n' "$REVERB_DATABASE_URL" | sed -E 's#^[a-z]+://[^@]+@([^:/]+).*#\1#')"
database_port="$(printf '%s\n' "$REVERB_DATABASE_URL" | sed -nE 's#^[a-z]+://[^@]+@[^:/]+:([0-9]+).*#\1#p')"
database_port="${database_port:-5432}"

until pg_isready -h "$database_host" -p "$database_port" -U postgres >/dev/null 2>&1; do
  echo "waiting for postgres at ${database_host}:${database_port}"
  sleep 1
done

start_wait="$(date +%s)"

until [[ -d "$REVERB_WORKSPACE_REPO_ROOT/.git" ]]; do
  echo "waiting for app repo at $REVERB_WORKSPACE_REPO_ROOT"
  sleep 2

  if [[ "$REVERB_WORKSPACE_WAIT_TIMEOUT_SECS" != "0" ]]; then
    now="$(date +%s)"
    elapsed="$((now - start_wait))"

    if (( elapsed >= REVERB_WORKSPACE_WAIT_TIMEOUT_SECS )); then
      echo "timed out waiting for app repo at $REVERB_WORKSPACE_REPO_ROOT" >&2
      exit 1
    fi
  fi
done

if [[ -f "$REVERB_WORKSPACE_REPO_ROOT/mix.exs" && ! -d "$REVERB_WORKSPACE_REPO_ROOT/deps" ]]; then
  mix -C "$REVERB_WORKSPACE_REPO_ROOT" deps.get
fi

mix ecto.create
mix ecto.migrate

if [[ "$REVERB_OPENCODE_WEB_ENABLED" == "true" ]]; then
  mkdir -p "$REVERB_OPENCODE_WEB_WORKDIR"

  (
    cd "$REVERB_OPENCODE_WEB_WORKDIR"
    exec opencode web --hostname "$REVERB_OPENCODE_WEB_HOST" --port "$REVERB_OPENCODE_WEB_PORT"
  ) &

  opencode_pid="$!"

  cleanup() {
    kill "$opencode_pid" >/dev/null 2>&1 || true
  }

  trap cleanup EXIT INT TERM

  elixir "$node_name_flag" "$REVERB_NODE_NAME" --cookie "$REVERB_ERLANG_COOKIE" -S mix run --no-halt &
  reverb_pid="$!"

  wait -n "$opencode_pid" "$reverb_pid"
  status="$?"
  kill "$reverb_pid" "$opencode_pid" >/dev/null 2>&1 || true
  wait "$reverb_pid" >/dev/null 2>&1 || true
  wait "$opencode_pid" >/dev/null 2>&1 || true
  exit "$status"
fi

exec elixir "$node_name_flag" "$REVERB_NODE_NAME" --cookie "$REVERB_ERLANG_COOKIE" -S mix run --no-halt
