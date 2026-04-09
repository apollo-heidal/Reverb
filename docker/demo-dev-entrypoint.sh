#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV="${MIX_ENV:-dev}"
export DEMO_DEV_NODE_NAME="${DEMO_DEV_NODE_NAME:-demo_dev@demo-dev}"
export REVERB_ERLANG_COOKIE="${REVERB_ERLANG_COOKIE:-reverb_demo_cookie}"
export DEMO_DEV_APP_ROOT="${DEMO_DEV_APP_ROOT:-/workspace/reverb_demo_app}"
export REVERB_PATH="${REVERB_PATH:-/opt/reverb}"

if [[ ! -d "$DEMO_DEV_APP_ROOT/.git" ]]; then
  mkdir -p "$(dirname "$DEMO_DEV_APP_ROOT")"
  rm -rf "$DEMO_DEV_APP_ROOT"
  cp -R /opt/reverb/examples/reverb_demo_app "$DEMO_DEV_APP_ROOT"
  git -C "$DEMO_DEV_APP_ROOT" init
  git -C "$DEMO_DEV_APP_ROOT" config user.name "Reverb Demo"
  git -C "$DEMO_DEV_APP_ROOT" config user.email "reverb-demo@example.invalid"
  git -C "$DEMO_DEV_APP_ROOT" add -A
  git -C "$DEMO_DEV_APP_ROOT" commit -m "Initial demo app state"
fi

cd "$DEMO_DEV_APP_ROOT"
mix deps.get
exec elixir --name "$DEMO_DEV_NODE_NAME" --cookie "$REVERB_ERLANG_COOKIE" -S mix run --no-halt
