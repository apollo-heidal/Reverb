#!/bin/sh
set -eu

if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  RESET=""
fi

check() { printf "%b%s%b %s\n" "$GREEN" "✓" "$RESET" "$1"; }
warn() { printf "%b%s%b %s\n" "$YELLOW" "!" "$RESET" "$1"; }
fail() { printf "%b%s%b %s\n" "$RED" "✗" "$RESET" "$1"; }
info() { printf "%b%s%b %s\n" "$BLUE" ">" "$RESET" "$1"; }
headline() { printf "\n%b%s%b\n" "$BOLD" "$1" "$RESET"; }

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
    exit 1
  fi
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

camelize() {
  printf '%s' "$1" | awk -F'[_ -]+' '{for (i = 1; i <= NF; i++) printf toupper(substr($i, 1, 1)) substr($i, 2)}'
}

random_alnum() {
  length="$1"
  od -An -N128 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-"$length"
}

container_engine=""
podman_compose_command=""
podman_conf_root=""
temp_root=""
script_dir=""

cleanup() {
  [ -n "$temp_root" ] && [ -d "$temp_root" ] && rm -rf "$temp_root"
  [ -n "$podman_conf_root" ] && [ -d "$podman_conf_root" ] && rm -rf "$podman_conf_root"
}

trap cleanup EXIT

if [ -n "${0:-}" ]; then
  script_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd || true)"
fi

configure_container_engine() {
  requested_engine="${REVERB_CONTAINER_ENGINE:-}"

  if [ -n "$requested_engine" ]; then
    case "$requested_engine" in
      docker|podman)
        require_command "$requested_engine"
        container_engine="$requested_engine"
        ;;
      *)
        fail "Unsupported container engine: $requested_engine"
        exit 1
        ;;
    esac

    return
  fi

  if command -v docker >/dev/null 2>&1; then
    container_engine="docker"
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    container_engine="podman"
    return
  fi

  fail "Missing required container engine: docker or podman"
  exit 1
}

configure_podman_networking() {
  if [ "$container_engine" != "podman" ]; then
    return
  fi

  current_rootless_cmd="$(podman info --format '{{.Host.RootlessNetworkCmd}}' 2>/dev/null || true)"

  if [ "$current_rootless_cmd" = "slirp4netns" ]; then
    return
  fi

  podman_conf_root="$(mktemp -d)"
  cat > "$podman_conf_root/containers.conf" <<EOF
[network]
default_rootless_network_cmd="slirp4netns"
EOF
  export CONTAINERS_CONF="$podman_conf_root/containers.conf"
  warn "Podman rootless networking defaults to $current_rootless_cmd; forcing slirp4netns for this install run"
}

configure_podman_compose_provider() {
  if [ "$container_engine" != "podman" ]; then
    return
  fi

  if [ -x "$HOME/.local/bin/podman-compose" ]; then
    podman_compose_command="$HOME/.local/bin/podman-compose"
    return
  fi

  if command -v podman-compose >/dev/null 2>&1; then
    podman_compose_command="$(command -v podman-compose)"
  fi
}

compose() {
  case "$container_engine" in
    docker)
      if [ -n "${compose_project_name:-}" ]; then
        docker compose -p "$compose_project_name" "$@"
      else
        docker compose "$@"
      fi
      ;;
    podman)
      if [ -n "$podman_compose_command" ]; then
        if [ -n "${compose_project_name:-}" ]; then
          "$podman_compose_command" -p "$compose_project_name" "$@"
        else
          "$podman_compose_command" "$@"
        fi
      else
        if [ -n "${compose_project_name:-}" ]; then
          podman compose -p "$compose_project_name" "$@"
        else
          podman compose "$@"
        fi
      fi
      ;;
  esac
}

port_in_use() {
  port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q .
    return
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  fail "Need either ss or lsof to detect whether port $port is available."
  exit 1
}

find_unused_port() {
  start_port="$1"
  port="$start_port"
  attempts=0

  while [ "$attempts" -lt 200 ]; do
    if ! port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi

    port=$((port + 1))
    attempts=$((attempts + 1))
  done

  return 1
}

random_port_between() {
  min_port="$1"
  max_port="$2"
  range_size=$((max_port - min_port + 1))
  random_value="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"

  printf '%s' $((min_port + (random_value % range_size)))
}

pick_random_unused_port() {
  min_port="$1"
  max_port="$2"
  attempts=0

  while [ "$attempts" -lt 200 ]; do
    candidate_port="$(random_port_between "$min_port" "$max_port")"

    if ! port_in_use "$candidate_port"; then
      printf '%s' "$candidate_port"
      return 0
    fi

    attempts=$((attempts + 1))
  done

  fail "Could not find an available port between $min_port and $max_port."
  exit 1
}

compose_down_for_project() {
  project_name="$1"
  project_dir="$2"

  if [ ! -d "$project_dir" ] || [ ! -f "$project_dir/docker-compose.yml" ]; then
    return 0
  fi

  info "Stopping existing compose project '$project_name' in $project_dir"

  case "$container_engine" in
    docker)
      docker compose -p "$project_name" -f "$project_dir/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
      ;;
    podman)
      if [ -n "$podman_compose_command" ]; then
        "$podman_compose_command" -p "$project_name" -f "$project_dir/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
      else
        podman compose -p "$project_name" -f "$project_dir/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

list_running_quickstart_projects_for_app() {
  app_slug="$1"
  compose_project="$2"
  seen_projects=""
  container_ids="$("$container_engine" ps -a --filter "label=com.docker.compose.project=$compose_project" --format '{{.ID}}' 2>/dev/null || true)"

  if [ -z "$container_ids" ]; then
    container_ids="$("$container_engine" ps -a --filter "label=dev.reverb.quickstart.managed=true" --filter "label=dev.reverb.quickstart.app=$app_slug" --format '{{.ID}}' 2>/dev/null || true)"
  fi

  if [ -z "$container_ids" ]; then
    return 0
  fi

  for container_id in $container_ids; do
    project_name="$("$container_engine" inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container_id" 2>/dev/null || true)"
    project_dir="$("$container_engine" inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_id" 2>/dev/null || true)"

    if [ -z "$project_name" ] || [ -z "$project_dir" ]; then
      continue
    fi

    project_key="$project_name|$project_dir"

    case ":$seen_projects:" in
      *":$project_key:"*) continue ;;
    esac

    if [ -n "$seen_projects" ]; then
      seen_projects="$seen_projects:$project_key"
    else
      seen_projects="$project_key"
    fi
  done

  printf '%s' "$seen_projects" | tr ':' '\n'
}

confirm_replacement_of_existing_app() {
  app_name="$1"
  app_slug="$2"
  compose_project="$3"
  target_dir="$4"
  existing_projects="$(list_running_quickstart_projects_for_app "$app_slug" "$compose_project")"

  if [ -z "$existing_projects" ]; then
    return 0
  fi

  warn "A Reverb quickstart app named '$app_name' is already running."

  printf '%s\n' "$existing_projects" | while IFS= read -r project_entry; do
    [ -n "$project_entry" ] || continue
    project_name="${project_entry%%|*}"
    project_dir="${project_entry#*|}"
    info "Existing app: compose project '$project_name' in $project_dir"
  done

  printf "%s\n" "Continuing will tear down the running app before starting the new one."

  if [ -e "$target_dir" ]; then
    printf "%s\n" "The existing project directory at $target_dir will also be removed."
  fi

  printf "%bProceed and replace the running app?%b [y/N]: " "$BOLD" "$RESET"
  read -r replacement_choice
  replacement_choice="${replacement_choice:-n}"

  case "$(printf '%s' "$replacement_choice" | tr '[:upper:]' '[:lower:]')" in
    y|yes) ;;
    *)
      fail "Installation cancelled. Choose a different project name or stop the existing app first."
      exit 1
      ;;
  esac

  printf '%s\n' "$existing_projects" | while IFS= read -r project_entry; do
    [ -n "$project_entry" ] || continue
    project_name="${project_entry%%|*}"
    project_dir="${project_entry#*|}"
    compose_down_for_project "$project_name" "$project_dir"

    if [ -e "$project_dir" ] && [ "$project_dir" != "$target_dir" ]; then
      info "Removing existing project directory $project_dir"
      rm -rf "$project_dir"
    fi
  done

  if [ -e "$target_dir" ]; then
    info "Removing existing project directory $target_dir"
    rm -rf "$target_dir"
  fi
}

resolve_host_port() {
  label="$1"
  preferred_port="$2"
  probe_path="$3"

  if ! port_in_use "$preferred_port"; then
    printf '%s' "$preferred_port"
    return 0
  fi

  warn "$label port $preferred_port is already in use" >&2
  info "Check http://127.0.0.1:$preferred_port$probe_path to see what is already running there." >&2
  printf "%bIs that already your %s instance?%b [y/N]: " "$BOLD" "$label" "$RESET" >&2
  read -r port_owner_choice
  port_owner_choice="${port_owner_choice:-n}"

  case "$(printf '%s' "$port_owner_choice" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      fail "Stop the existing $label service or set a different port, then re-run the installer." >&2
      exit 1
      ;;
  esac

  replacement_port="$(find_unused_port $((preferred_port + 1)))" || {
    fail "Could not find an available port for $label." >&2
    exit 1
  }

  warn "Using port $replacement_port for $label instead." >&2
  printf '%s' "$replacement_port"
}

wait_for_url() {
  label="$1"
  url="$2"
  seconds="${3:-180}"
  started="$(date +%s)"

  until curl -fsS "$url" >/dev/null 2>&1; do
    now="$(date +%s)"
    elapsed=$((now - started))

    if [ "$elapsed" -ge "$seconds" ]; then
      fail "Timed out waiting for $label at $url"
      exit 1
    fi

    sleep 2
  done

  check "$label is ready"
}

existing_app_default="n"
printf "%bInstall into an existing Phoenix app?%b [y/N]: " "$BOLD" "$RESET"
read -r existing_app_choice
existing_app_choice="${existing_app_choice:-$existing_app_default}"

case "$(printf '%s' "$existing_app_choice" | tr '[:upper:]' '[:lower:]')" in
  y|yes)
    headline "Existing Phoenix App"

    if [ ! -f "mix.exs" ] || ! ls lib/*_web/router.ex >/dev/null 2>&1; then
      fail "Current directory does not look like a Phoenix app. Run this from your app root."
      exit 1
    fi

    require_command mix

    if ! mix help reverb.install >/dev/null 2>&1; then
      fail "The `mix reverb.install` task is not available in this app yet. Add the Reverb dependency first, run mix deps.get, then re-run this installer."
      exit 1
    fi

    mix reverb.install --patch-config
    check "Reverb install completed"

    printf "\nPlace /captain behind your existing authenticated scope manually if you enable it later.\n"
    exit 0
    ;;
esac

project_name_default="my-reverb-app"
printf "%bProject name%b [%s]: " "$BOLD" "$RESET" "$project_name_default"
read -r project_name
project_name="${project_name:-$project_name_default}"
project_slug="$(slugify "$project_name")"
project_parent="$(pwd)"

if [ -n "$script_dir" ] && [ -f "$script_dir/mix.exs" ] && [ -f "$script_dir/docker/quickstart-compose.yml" ]; then
  if [ "$(basename "$script_dir")" = "reverb" ] && [ "$(basename "$(dirname "$script_dir")")" = "reverb-apps" ]; then
    project_parent="$(dirname "$script_dir")"
  else
    project_parent="$(dirname "$script_dir")/reverb-apps"
  fi

  info "Local Reverb checkout detected; quickstart apps will be created under $project_parent"
fi

if [ -z "$project_slug" ]; then
  fail "Could not derive a project slug from '$project_name'."
  exit 1
fi

project_dir="$project_parent/$project_slug"
project_basename="$(basename "$project_dir")"
compose_project_name="reverb-${project_slug}"

require_command curl
require_command tar
configure_container_engine
configure_podman_networking
configure_podman_compose_provider

confirm_replacement_of_existing_app "$project_name" "$project_slug" "$compose_project_name" "$project_dir"

printf "%s\n" "The initial admin email is only written into local quickstart config on this machine."
printf "%bInitial admin email for admin login%b: " "$BOLD" "$RESET"
read -r initial_admin_email

case "$initial_admin_email" in
  *@*) ;;
  *)
    fail "Please enter a valid admin email address."
    exit 1
    ;;
esac

repo_tarball_url="${REVERB_INSTALL_TARBALL_URL:-https://github.com/apollo-heidal/reverb/archive/refs/heads/main.tar.gz}"

headline "Reverb Quickstart"
info "Project directory: $project_dir"

if [ -n "${QUICKSTART_HOST_APP_PORT:-}" ]; then
  app_host_port="$(resolve_host_port "Phoenix app" "$QUICKSTART_HOST_APP_PORT" "/")"
else
  app_host_port="$(pick_random_unused_port 4000 4999)"
fi

if [ -n "${QUICKSTART_HOST_OPENCODE_PORT:-}" ]; then
  opencode_host_port="$(resolve_host_port "OpenCode web" "$QUICKSTART_HOST_OPENCODE_PORT" "/global/health")"
else
  opencode_host_port="$(pick_random_unused_port 5000 5999)"
fi

info "App host port: $app_host_port"
info "OpenCode host port: $opencode_host_port"

if [ -e "$project_dir" ]; then
  fail "Target directory already exists: $project_dir"
  exit 1
fi

source_root=""

if [ -n "$script_dir" ] && [ -f "$script_dir/mix.exs" ] && [ -f "$script_dir/docker/quickstart-compose.yml" ]; then
  source_root="$script_dir"
fi

if [ -z "$source_root" ]; then
  headline "Downloading Reverb"
  temp_root="$(mktemp -d)"
  curl -fsSL "$repo_tarball_url" | tar -xzf - -C "$temp_root"

  for candidate in "$temp_root"/*; do
    if [ -d "$candidate" ]; then
      source_root="$candidate"
      break
    fi
  done

  if [ -z "$source_root" ]; then
    fail "Could not locate the extracted Reverb source bundle."
    exit 1
  fi

  check "Fetched Reverb source bundle"
else
  check "Using local Reverb source"
fi

if [ -n "$source_root" ] && [ "$(basename "$project_parent")" = "reverb-apps" ]; then
  mkdir -p "$project_parent"

  if [ ! -e "$project_parent/reverb" ]; then
    ln -s "$source_root" "$project_parent/reverb"
    info "Linked local checkout at $project_parent/reverb"
  fi
fi

mkdir -p "$project_dir" "$project_dir/.reverb-src" "$project_dir/docker"

headline "Scaffolding Project"

set -- --exclude='.git' --exclude='_build' --exclude='deps' --exclude='tmp' --exclude='plans' --exclude='quickstart'

case "$project_dir" in
  "$source_root"/*) set -- "$@" --exclude="$project_basename" ;;
esac

(cd "$source_root" && tar "$@" -cf - .) | (cd "$project_dir/.reverb-src" && tar -xf -)
cp "$source_root/docker/quickstart-compose.yml" "$project_dir/docker-compose.yml"
cp "$source_root/docker/quickstart-app.Dockerfile" "$project_dir/Dockerfile.app"
cp "$source_root/docker/quickstart-app-entrypoint.sh" "$project_dir/docker/app-entrypoint.sh"
cp "$source_root/docker/quickstart.dockerignore" "$project_dir/.dockerignore"
chmod +x "$project_dir/docker/app-entrypoint.sh"
check "Created project files"

topic_hash="captain-${project_slug}-$(date +%s)"
erlang_cookie="$(random_alnum 48)"
secret_key_base="$(random_alnum 64)"
initial_admin_password="$(random_alnum 96)"
quickstart_app_name="$(printf '%s' "$project_slug" | tr '-' '_')"

case "$quickstart_app_name" in
  [0-9]*) quickstart_app_name="app_${quickstart_app_name}" ;;
esac

quickstart_app_module="$(camelize "$quickstart_app_name")"
reverb_pubsub_name="${quickstart_app_module}.PubSub"
reverb_control_module="${quickstart_app_module}.Reverb.Control"

cat > "$project_dir/.env.reverb" <<EOF
REVERB_PROJECT_NAME=$project_name
REVERB_QUICKSTART_APP=$project_slug
REVERB_QUICKSTART_FINGERPRINT=reverb-quickstart-v1
REVERB_TOPIC_HASH=$topic_hash
REVERB_ERLANG_COOKIE=$erlang_cookie
REVERB_APP_SECRET_KEY_BASE=$secret_key_base
REVERB_PUBSUB_NAME=$reverb_pubsub_name
REVERB_CONTROL_MODULE=$reverb_control_module
REVERB_AGENT_MODEL=gpt-5.4
QUICKSTART_APP_NAME=$quickstart_app_name
QUICKSTART_APP_MODULE=$quickstart_app_module
QUICKSTART_HOST_APP_PORT=$app_host_port
QUICKSTART_HOST_OPENCODE_PORT=$opencode_host_port
QUICKSTART_APP_URL=http://localhost:$app_host_port
QUICKSTART_OPENCODE_URL=http://localhost:$opencode_host_port
INITIAL_ADMIN_EMAIL=$initial_admin_email
INITIAL_ADMIN_PASSWORD=$initial_admin_password
EOF

export REVERB_QUICKSTART_APP="$project_slug"
export REVERB_QUICKSTART_FINGERPRINT="reverb-quickstart-v1"
export QUICKSTART_HOST_APP_PORT="$app_host_port"
export QUICKSTART_HOST_OPENCODE_PORT="$opencode_host_port"

check "Wrote .env.reverb"

headline "Credentials"
printf "%bAdmin email:%b %s\n" "$BOLD" "$RESET" "$initial_admin_email"
printf "%bAdmin password:%b %s\n" "$BOLD" "$RESET" "$initial_admin_password"
printf "%s\n" "Store these credentials securely. Recovery emails will not work until you configure an email relay service, and Reverb quickstart does not set that up for you."
printf "%s\n" "If you lose this password, recovery is more complex. See the README for the persisted app env recovery path."

while :; do
  printf "%bType WRITTEN after you have stored the admin password%b: " "$BOLD" "$RESET"
  read -r password_confirmation

  if [ "$password_confirmation" = "WRITTEN" ]; then
    break
  fi

  warn "The installer will wait until you confirm the password has been written down."
done

headline "Starting Containers"
compose -f "$project_dir/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
compose -f "$project_dir/docker-compose.yml" up --build -d
check "Compose stack is booting"

wait_for_url "Phoenix app" "http://127.0.0.1:$app_host_port" 1200
wait_for_url "OpenCode web" "http://127.0.0.1:$opencode_host_port/global/health" 300

headline "Connect A Provider"
printf "Open these in your browser:\n"
printf "  - App UI: %s\n" "http://localhost:$app_host_port"
printf "  - OpenCode web: %s\n\n" "http://localhost:$opencode_host_port"
printf "%s\n" "In OpenCode web, click the gear in the lower-left corner, then open the Providers tab to connect a provider."
printf "%s\n" "Do not steer the app from OpenCode web. Use http://localhost:$app_host_port/captain for product requests."

headline "Resuming Reverb"
compose -f "$project_dir/docker-compose.yml" exec -T reverb sh -lc 'curl -fsS -X POST http://127.0.0.1:4010/api/scheduler/resume >/dev/null'
check "Reverb scheduler resumed"

headline "Ready"
printf "%bCaptain your app here:%b %s\n" "$BOLD" "$RESET" "http://localhost:$app_host_port/captain"
printf "%bOpenCode web:%b %s\n" "$BOLD" "$RESET" "http://localhost:$opencode_host_port"
printf "%bProject folder:%b %s\n" "$BOLD" "$RESET" "$project_dir"
