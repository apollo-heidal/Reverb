#!/usr/bin/env bash
set -euo pipefail

export MIX_ENV="${MIX_ENV:-dev}"
export PORT="${PORT:-4000}"
export PHX_HOST="${PHX_HOST:-localhost}"
export DATABASE_URL="${DATABASE_URL:-ecto://postgres:postgres@prod-db/quickstart_dev}"
export APP_NODE_NAME="${APP_NODE_NAME:-prod}"
export APP_USE_SHORTNAME="${APP_USE_SHORTNAME:-true}"
export REVERB_ERLANG_COOKIE="${REVERB_ERLANG_COOKIE:-reverb_quickstart_cookie}"
export QUICKSTART_APP_MODULE="${QUICKSTART_APP_MODULE:?missing QUICKSTART_APP_MODULE}"
export REVERB_QUICKSTART_APP="${REVERB_QUICKSTART_APP:?missing REVERB_QUICKSTART_APP}"
export QUICKSTART_WORKSPACE_ROOT="${QUICKSTART_WORKSPACE_ROOT:-/workspace_root}"
export INITIAL_ADMIN_EMAIL="${INITIAL_ADMIN_EMAIL:?missing INITIAL_ADMIN_EMAIL}"
export INITIAL_ADMIN_PASSWORD="${INITIAL_ADMIN_PASSWORD:?missing INITIAL_ADMIN_PASSWORD}"

node_name_flag="--name"

if [[ "$APP_USE_SHORTNAME" == "true" ]]; then
  node_name_flag="--sname"
fi

app_root="$QUICKSTART_WORKSPACE_ROOT/$REVERB_QUICKSTART_APP/app"
database_host="$(printf '%s\n' "$DATABASE_URL" | sed -E 's#^[a-z]+://[^@]+@([^:/]+).*#\1#')"
database_port="$(printf '%s\n' "$DATABASE_URL" | sed -nE 's#^[a-z]+://[^@]+@[^:/]+:([0-9]+).*#\1#p')"
database_port="${database_port:-5432}"

until pg_isready -h "$database_host" -p "$database_port" -U postgres >/dev/null 2>&1; do
  echo "waiting for postgres at ${database_host}:${database_port}"
  sleep 1
done

if [[ ! -f "$app_root/mix.exs" ]]; then
  echo "missing generated app at $app_root" >&2
  exit 1
fi

cd "$app_root"
mix deps.get
mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate
mix run -e '
app_module = System.fetch_env!("QUICKSTART_APP_MODULE")
accounts = Module.concat([app_module, "Accounts"])
user = Module.concat([app_module, "Accounts", "User"])
email = String.trim(System.get_env("INITIAL_ADMIN_EMAIL") || "")
password = String.trim(System.get_env("INITIAL_ADMIN_PASSWORD") || "")

if email != "" and password != "" do
  require Ash.Query

  query = Ash.Query.filter(user, email == ^email)

  case Ash.read_one(query, domain: accounts, authorize?: false) do
    {:ok, nil} ->
      attrs = %{
        email: email,
        password: password,
        password_confirmation: password
      }

      changeset = Ash.Changeset.for_create(user, :register_with_password, attrs)

      case Ash.create(changeset, domain: accounts, authorize?: false) do
        {:ok, _user} -> :ok
        {:error, error} -> raise "failed to create initial admin user: #{inspect(error)}"
      end

    {:ok, _user} ->
      :ok

    {:error, error} ->
      raise "failed to load initial admin user: #{inspect(error)}"
  end
end
'
mix assets.deploy

exec elixir "$node_name_flag" "$APP_NODE_NAME" --cookie "$REVERB_ERLANG_COOKIE" -S mix phx.server
