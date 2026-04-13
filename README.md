# Reverb

Reverb is a generic Elixir library and standalone coordinator for BEAM
applications that need a safe `prod -> analyze -> develop in sandbox -> validate
-> promote` loop.

It is designed to sit between two loops:

1. A production BEAM app emits structured runtime signals over PubSub.
2. A coordinator running in a secure development sandbox receives those
   signals, turns them into durable tasks, executes isolated agent-driven
   remediation attempts, validates the result in a sandbox copy of the target
   app, and optionally promotes the change through a controlled git/PR flow.

This repo contains both halves:

- `mode: :emitter` for host applications
- `mode: :receiver` for the standalone coordinator

## Current Architecture

The current implementation includes:

- Emitter-side message broadcasting via `Reverb.emit/3`
- Receiver-side BEAM node guard and PubSub listener
- Durable task store plus raw message audit store
- Expanded task metadata for steering, leasing, validation, and promotion state
- Durable run records for execution attempts
- Subject claims to prevent duplicate concurrent work
- Scheduler-backed `Reverb.Agent.Loop` with worker slots
- Workspace pool and path-safety checks
- Coordinator-owned git boundary with protected branch rules
- CLI adapter boundary for coding agents
- Validation command runner
- Runtime status/events projection for steering surfaces
- Merge/deploy feedback ingestion via `Reverb.ingest_feedback/1`

## What Is Not Built Yet

The architecture is in place, but these pieces are still intentionally thin:

- Localhost steering web UI and JSON API
- Rich merge/reconciliation policy beyond branch-local commits
- Full remote promotion workflows beyond the initial `gh`-backed path
- Per-target-app deployment/reload adapters
- Productionized release packaging

## Host App Usage

Add Reverb to a BEAM app and configure emitter mode:

```elixir
config :reverb,
  mode: :emitter,
  topic_hash: "my-app-prod",
  pubsub_name: MyApp.PubSub

config :reverb, Reverb.Emitter,
  logger_handler: true,
  levels: [:error, :warning]
```

Emit messages directly:

```elixir
Reverb.emit(:error, "Payment processing failed", source: "MyApp.Payments.charge/2")
Reverb.emit(:manual, "Investigate the deployment health check")
```

## Coordinator Usage

Configure receiver mode in the standalone coordinator:

```elixir
config :reverb,
  mode: :receiver,
  topic_hash: "my-app-prod",
  pubsub_name: MyApp.PubSub

config :reverb, Reverb.Receiver,
  prod_node: :"my_app@prod-host",
  allowed_nodes: [:"my_app@prod-host"]

config :reverb, Reverb.Workspaces,
  repo_root: "/path/to/isolated/app/clone",
  root: "/tmp/reverb/workspaces"

config :reverb, Reverb.Agent,
  enabled: true,
  max_agents: 1,
  agent_command: "opencode",
  agent_args: ["run", "--format", "json", "--dangerously-skip-permissions"],
  agent_adapter: :opencode,
  agent_model: "gpt-5.4"
```

Legacy adapters remain available, but `:hermes`, `:codex`, `:claude`, and
`:generic` are retained compatibility paths and are not production-complete.

Optional validation:

```elixir
config :reverb, Reverb.Validation,
  commands: [
    "mix compile",
    "mix test"
  ]
```

Validation commands coming from task metadata are prefix-allowlisted by default.
Commands outside `mix compile` and `mix test`, or commands containing shell
control operators such as `;`, `&&`, `||`, and `|`, are rejected unless you
explicitly relax the validation policy.

Optional remote promotion:

```elixir
config :reverb, Reverb.Git,
  remote_enabled: true,
  push_enabled: true,
  auto_promote: false,
  remote_backend: :gh,
  protected_branches: ["main", "master", "prod"]
```

Set `auto_promote: false` to stop after local validation and place the task in
`awaiting_approval`. Then call `Reverb.approve_task/1` to push the branch and
open the PR.

Set `config :reverb, yolo_mode: true` if you want Reverb to merge each
validated task branch straight back into the repo base branch and then
best-effort push `origin/<base>` when that remote exists.

When YOLO mode is enabled, Reverb can also use a fixed BEAM RPC control module
inside the prod app for release migrations and restarts. Distributed Erlang is
inherently duplex transport, but Reverb itself will not attempt mutating prod
RPC when `config :reverb, yolo_mode: false`.

## Public APIs

- `Reverb.emit/3`
- `Reverb.status/0`
- `Reverb.pause/0`
- `Reverb.resume/0`
- `Reverb.tasks/1`
- `Reverb.get_task/1`
- `Reverb.runs/1`
- `Reverb.get_run/1`
- `Reverb.create_manual_task/1`
- `Reverb.retry_task/1`
- `Reverb.cancel_task/1`
- `Reverb.approve_task/1`
- `Reverb.ingest_feedback/1`
- `Reverb.reprioritize_task/2`
- `Reverb.update_task_notes/2`
- `Reverb.agents_status/0`

## Operator HTTP

Enable the built-in operator surface in receiver mode:

```elixir
config :reverb, Reverb.Operator,
  enabled: true,
  port: 4010
```

Available endpoints:

- `GET /health`
- `GET /api/status`
- `GET /api/tasks`
- `GET /api/runs`
- `POST /api/scheduler/pause`
- `POST /api/scheduler/resume`

Runtime env overrides are also supported:

- `REVERB_OPERATOR_ENABLED=true`
- `REVERB_OPERATOR_PORT=4010`

## Development

The repo currently depends on Postgres for task and run persistence.

For a stable local toolchain, prefer the included Nix shell:

```bash
nix develop
mix test
```

## Quickstart Smoke Test

The canonical end-to-end smoke path is the root installer. It creates a fresh
Phoenix app with `mix phx.new`, installs AshAuthentication for simple
email/password auth, installs Reverb, seeds an initial admin account, and
enables the `/captain` steering UI for that admin user.

To run it from this repo locally:

```bash
sh install.sh
```

The installer supports both `docker compose` and `podman compose`. Set
`REVERB_CONTAINER_ENGINE=podman` if you want to force the Podman path.

If `4000` or `4096` are already in use, set `QUICKSTART_HOST_APP_PORT` and
`QUICKSTART_HOST_OPENCODE_PORT` before running the installer.

The intended one-line remote form is:

```bash
curl -fsSL https://raw.githubusercontent.com/apollo-heidal/reverb/main/install.sh | sh
```

The quickstart stack exposes:

- `localhost:4000` for the generated Phoenix app and `/captain`
- `localhost:4096` for OpenCode web running inside the Reverb container
- a `prod` app container generated from `phx.new`
- a standalone `reverb` coordinator container
- separate Postgres containers for the app and Reverb state

The installer prompts for an initial admin email, then generates a very strong
password and stores it in `.env.reverb`. Save that password securely. Recovery
emails will not work until you configure an email relay service for the app,
and Reverb quickstart does not set that up for you.

If you lose the generated password, recovery is more manual: inspect the
persisted app env used by the prod container and read `INITIAL_ADMIN_PASSWORD`
from there.

For real provider-backed runs, put agent auth only in a coordinator env file
such as `.env.reverb` and load it into the Reverb container with `env_file`.
Typical examples are `OPENCODE_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, and `GH_TOKEN`. Reverb should receive these as container env
vars, not embed them in prompts, task metadata, or log output.

If you use OpenCode's TUI login flow with ChatGPT Plus/Pro, you do not need an
OpenAI API key. Authenticate in OpenCode with `/connect`, select `OpenAI`, then
choose `ChatGPT Plus/Pro`. OpenCode stores that login at
`~/.local/share/opencode/auth.json`. For a containerized Reverb coordinator,
mount `~/.local/share/opencode` from the host into the container at
`/root/.local/share/opencode` so the in-container `opencode` binary can reuse
the same auth session.

During quickstart setup, connect a provider through `localhost:4096`, but do
not steer the app from OpenCode web. Use `localhost:4000/captain` for product
requests. In OpenCode web, click the gear in the lower-left corner and open the
Providers tab to connect a provider. Captain tasks can queue freely, and Reverb
schedules them before automated log-derived work.

## Installation Scaffold

The shell installer supports both flows:

- New app quickstart: `sh install.sh`
- Existing Phoenix app: run `sh install.sh` from the app root, choose the
  existing-app path, and make sure the Reverb dependency is already present so
  `mix reverb.install` is available.

To generate starter files in another Elixir project directly, run:

```bash
mix reverb.install --pubsub MyApp.PubSub --topic-hash my-app-prod
```

Add `--patch-config` if you want the installer to append
`import_config "reverb.exs"` to `config/config.exs` automatically.

Add `--quickstart --captain` only for the fresh quickstart app path after
AshAuthentication has already been installed.

Captain is a core Reverb surface, but it should stay authenticated. In existing
apps, do not mount `/captain` unless you place it behind your own authenticated
scope first.

## Operator Runbook

Common commands:

```bash
curl http://127.0.0.1:4010/health
curl http://127.0.0.1:4010/api/status
curl http://127.0.0.1:4010/api/tasks
curl -X POST http://127.0.0.1:4010/api/scheduler/pause
curl -X POST http://127.0.0.1:4010/api/scheduler/resume
```

For flake-based local work, run tests with `MIX_ENV=test` explicitly:

```bash
nix develop -c env MIX_ENV=test mix test
```

Test status for the current refactor:

- `mix test` passes
- 51 tests, 0 failures

In this workspace, tests were run through Nix:

```bash
nix shell nixpkgs#elixir nixpkgs#erlang -c mix deps.get
nix shell nixpkgs#elixir nixpkgs#erlang -c mix test
```
