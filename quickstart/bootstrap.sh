#!/bin/sh
set -eu

if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"
  DIM="$(printf '\033[2m')"
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""
  DIM=""
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
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

camelize() {
  printf '%s' "$1" | awk -F'[_ -]+' '{for (i = 1; i <= NF; i++) printf toupper(substr($i, 1, 1)) substr($i, 2)}'
}

random_alnum() {
  length="$1"
  value="$(od -An -N64 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-"$length")"
  printf '%s' "$value"
}

project_name_default="my-reverb-app"
printf "%bProject name%b [%s]: " "$BOLD" "$RESET" "$project_name_default"
read -r project_name
project_name="${project_name:-$project_name_default}"
project_slug="$(slugify "$project_name")"

if [ -z "$project_slug" ]; then
  fail "Could not derive a project slug from '$project_name'."
  exit 1
fi

project_dir="$(pwd)/$project_slug"
repo_tarball_url="${REVERB_QUICKSTART_TARBALL_URL:-https://github.com/apollo-heidal/reverb/archive/refs/heads/main.tar.gz}"

headline "Reverb Quickstart"
info "Project directory: $project_dir"

require_command curl
require_command docker
require_command tar

if docker info >/dev/null 2>&1; then
  check "Docker engine is running"
else
  fail "Docker engine is not running"
  printf "\nInstall or start Docker Desktop, then run this installer again:\n"
  printf "%s\n" "https://www.docker.com/products/docker-desktop/"
  exit 1
fi

if [ -e "$project_dir" ]; then
  fail "Target directory already exists: $project_dir"
  exit 1
fi

source_root=""

if [ -n "${0:-}" ]; then
  script_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd || true)"

  if [ -n "$script_dir" ] && [ -f "$script_dir/../mix.exs" ] && [ -d "$script_dir/templates/project" ]; then
    source_root="$(cd "$script_dir/.." >/dev/null 2>&1 && pwd)"
  fi
fi

temp_root=""

if [ -z "$source_root" ]; then
  headline "Downloading Reverb"
  temp_root="$(mktemp -d)"
  trap 'rm -rf "$temp_root"' EXIT
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

mkdir -p "$project_dir"
mkdir -p "$project_dir/.reverb-src"

headline "Scaffolding Project"

(cd "$source_root" && tar --exclude='.git' -cf - .) | (cd "$project_dir/.reverb-src" && tar -xf -)
cp -R "$source_root/quickstart/templates/project/." "$project_dir"
chmod +x "$project_dir/docker/app-entrypoint.sh"
chmod +x "$project_dir/docker/inject-captain.sh"
check "Created project files"

topic_hash="captain-${project_slug}-$(date +%s)"
erlang_cookie="$(random_alnum 48)"
secret_key_base="$(random_alnum 64)"
quickstart_app_name="$(printf '%s' "$project_slug" | tr '-' '_')"

case "$quickstart_app_name" in
  [0-9]*) quickstart_app_name="app_${quickstart_app_name}" ;;
esac

quickstart_app_module="$(camelize "$quickstart_app_name")"
reverb_pubsub_name="${quickstart_app_module}.PubSub"

cat > "$project_dir/.env.reverb" <<EOF
REVERB_PROJECT_NAME=$project_name
REVERB_TOPIC_HASH=$topic_hash
REVERB_ERLANG_COOKIE=$erlang_cookie
REVERB_APP_SECRET_KEY_BASE=$secret_key_base
REVERB_PUBSUB_NAME=$reverb_pubsub_name
REVERB_AGENT_MODEL=gpt-5.4
QUICKSTART_APP_NAME=$quickstart_app_name
QUICKSTART_APP_MODULE=$quickstart_app_module
EOF

check "Wrote .env.reverb"

headline "Starting Containers"
docker compose -f "$project_dir/docker-compose.yml" up --build -d
check "Compose stack is booting"

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

wait_for_url "Phoenix app" "http://127.0.0.1:4000" 240
wait_for_url "OpenCode web" "http://127.0.0.1:4096/global/health" 240

provider_ids() {
  curl -fsS "http://127.0.0.1:4096/provider" 2>/dev/null \
    | grep -o '"id":"[^"]*"' \
    | cut -d '"' -f4 \
    | sort -u
}

connected_providers() {
  curl -fsS "http://127.0.0.1:4096/provider" 2>/dev/null \
    | tr -d '\n' \
    | sed -n 's/.*"connected":\[\([^]]*\)\].*/\1/p' \
    | tr -d '"' \
    | tr ',' '\n' \
    | sed '/^$/d'
}

headline "Connect A Provider"
printf "%bOpen these in your browser:%b\n" "$BOLD" "$RESET"
printf "  - App UI: %s\n" "http://localhost:4000"
printf "  - OpenCode auth UI: %s\n\n" "http://localhost:4096"

printf "%bSupported providers include:%b\n" "$BOLD" "$RESET"
providers="$(provider_ids || true)"

if [ -n "$providers" ]; then
  printf '%s\n' "$providers" | sed 's/^/  - /'
else
  printf '%s\n' \
    "  - openai" \
    "  - opencode-zen" \
    "  - github-copilot" \
    "  - gitlab" \
    "  - anthropic" \
    "  - openrouter" \
    "  - google-vertex-ai" \
    "  - amazon-bedrock" \
    "  - ollama" \
    "  - groq"
fi

printf "\n%bImportant:%b connect your provider in OpenCode, but %bdo not steer the app from that UI%b.\n" "$BOLD" "$RESET" "$BOLD" "$RESET"
printf "Use %bhttp://localhost:4000/captain%b for app requests.\n" "$BOLD" "$RESET"

if [ -n "$(connected_providers || true)" ]; then
  check "Provider already connected"
else
  info "Waiting for your first connected provider..."

  while :; do
    providers_connected="$(connected_providers || true)"

    if [ -n "$providers_connected" ]; then
      break
    fi

    sleep 3
  done

  check "Connected provider detected"
  printf '%s\n' "$providers_connected" | sed 's/^/  - /'
fi

headline "Resuming Reverb"
docker compose -f "$project_dir/docker-compose.yml" exec -T reverb sh -lc 'curl -fsS -X POST http://127.0.0.1:4010/api/scheduler/resume >/dev/null'
check "Reverb scheduler resumed"

headline "Ready"
printf "%bCaptain your app here:%b %s\n" "$BOLD" "$RESET" "http://localhost:4000/captain"
printf "%bOpenCode auth UI:%b %s\n" "$BOLD" "$RESET" "http://localhost:4096"
printf "%bProject folder:%b %s\n" "$BOLD" "$RESET" "$project_dir"

printf "\n%bNotes%b\n" "$BOLD" "$RESET"
printf "%s\n" "- Automated log-based Reverb capture is already on."
printf "%s\n" "- Captain tasks queue freely, but they run before automated tasks."
printf "%s\n" "- To reuse your existing OpenCode auth, replace the named opencode volume with a host bind mount in docker-compose.yml."
