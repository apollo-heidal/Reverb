defmodule Mix.Tasks.Reverb.Install do
  use Mix.Task

  @shortdoc "Generates starter Reverb integration files for the current project"

  @moduledoc """
  Generates starter files to connect the current Elixir project to a standalone
  Reverb coordinator.

      mix reverb.install
      mix reverb.install --pubsub MyApp.PubSub --topic-hash my-app-prod

  This task intentionally generates additive files and avoids rewriting
  existing config files aggressively.
  """

  @switches [force: :boolean, patch_config: :boolean, pubsub: :string, topic_hash: :string]

  @impl true
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)
    app = Mix.Project.config()[:app] |> to_string()
    module_base = Macro.camelize(app)
    pubsub = opts[:pubsub] || "#{module_base}.PubSub"
    topic_hash = opts[:topic_hash] || "#{app}-prod"
    force? = opts[:force] || false
    patch_config? = opts[:patch_config] || false

    targets = [
      {"config/reverb.exs", config_template(pubsub, topic_hash)},
      {".env.reverb", env_template(app, topic_hash)},
      {".reverb.cookie.example", cookie_template()},
      {"docker-compose.reverb.yml", compose_template(app)},
      {"README.reverb.md", readme_template(app, pubsub, topic_hash)}
    ]

    Enum.each(targets, fn {path, contents} ->
      write_file(path, contents, force?)
    end)

    if patch_config? do
      patch_main_config!()
    end

    Mix.shell().info("""

    Reverb starter files generated.

    Next steps:
      1. Add `import_config "reverb.exs"` to your main config if desired.
      2. Set a shared cookie and agent auth in `.env.reverb`.
      3. Boot the standalone coordinator with `docker compose -f docker-compose.reverb.yml up`.
    """)
  end

  defp patch_main_config! do
    path = "config/config.exs"

    if File.exists?(path) do
      contents = File.read!(path)

      if String.contains?(contents, ~s(import_config "reverb.exs")) do
        Mix.shell().info("skip #{path} (already imports reverb.exs)")
      else
        File.write!(path, String.trim_trailing(contents) <> "\nimport_config \"reverb.exs\"\n")
        Mix.shell().info("patched #{path} with import_config \"reverb.exs\"")
      end
    else
      Mix.shell().info("skip #{path} (missing, patch manually)")
    end
  end

  defp write_file(path, contents, force?) do
    if File.exists?(path) and not force? do
      Mix.shell().info("skip #{path} (already exists, use --force to overwrite)")
    else
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, contents)
      Mix.shell().info("wrote #{path}")
    end
  end

  defp config_template(pubsub, topic_hash) do
    """
    import Config

    config :reverb,
      mode: :emitter,
      topic_hash: "#{topic_hash}",
      pubsub_name: #{pubsub}

    config :reverb, Reverb.Emitter,
      logger_handler: false,
      telemetry_events: []

    config :reverb, Reverb.Validation,
      commands: [
        "mix compile",
        "mix test"
      ]

    config :reverb, Reverb.Git,
      remote_enabled: false,
      push_enabled: false,
      auto_promote: false,
      protected_branches: ["main", "master", "prod", "production"]
    """
  end

  defp env_template(app, topic_hash) do
    """
    REVERB_TOPIC_HASH=#{topic_hash}
    REVERB_PUBSUB_NAME=#{Macro.camelize(app)}.PubSub
    REVERB_ERLANG_COOKIE=replace-me-with-a-shared-cookie
    REVERB_AGENT_ADAPTER=opencode
    REVERB_AGENT_COMMAND=opencode
    REVERB_AGENT_MODEL=gpt-5.4
    REVERB_AGENT_ARGS=run;;--format;;json;;--dangerously-skip-permissions
    REVERB_GIT_AUTO_PROMOTE=false
    REVERB_OPERATOR_ENABLED=true
    REVERB_OPERATOR_PORT=4010

    # Provider and agent auth examples. Keep secrets only in this env file.
    OPENCODE_API_KEY=
    OPENAI_API_KEY=
    ANTHROPIC_API_KEY=
    GEMINI_API_KEY=
    GH_TOKEN=
    """
  end

  defp cookie_template do
    Base.encode16(:crypto.strong_rand_bytes(24), case: :lower) <> "\n"
  end

  defp compose_template(app) do
    """
    services:
      reverb:
        image: ghcr.io/your-org/reverb:latest
        env_file:
          - .env.reverb
        environment:
          REVERB_MODE: receiver
          REVERB_AGENT_ENABLED: true
          REVERB_AGENT_ADAPTER: opencode
          REVERB_AGENT_COMMAND: opencode
          REVERB_AGENT_MODEL: gpt-5.4
          REVERB_AGENT_ARGS: run;;--format;;json;;--dangerously-skip-permissions
          REVERB_VALIDATION_COMMANDS: mix compile;;mix test
          REVERB_OPERATOR_ENABLED: true
          REVERB_OPERATOR_PORT: 4010
          REVERB_PROD_NODE: #{app}@host.docker.internal
          REVERB_ALLOWED_NODES: #{app}@host.docker.internal
          REVERB_WORKSPACE_REPO_ROOT: /sandbox/#{app}
          REVERB_WORKSPACE_ROOT: /workspaces
        volumes:
          - ./tmp/reverb-workspaces:/workspaces
          - ./:/sandbox/#{app}
          # Optional: mount OpenCode TUI auth from the host when using ChatGPT Plus/Pro.
          # - ${HOME}/.local/share/opencode:/root/.local/share/opencode:ro
    """
  end

  defp readme_template(app, pubsub, topic_hash) do
    """
    # Reverb Integration

    Generated for `#{app}`.

    ## Add To Your App

    1. Add `{:reverb, path: "..."}`
    2. Import `config/reverb.exs` from your config tree.
    3. Ensure your PubSub is started: `#{pubsub}`.
    4. Set the shared cookie and topic hash in `.env.reverb`.
    5. Add any provider auth keys needed by your chosen agent CLI to `.env.reverb`.

    ## Shared Values

    - Topic hash: `#{topic_hash}`
    - Cookie source: `.reverb.cookie.example`
    - Coordinator env file: `.env.reverb`

    ## Safe Defaults

    - Remote push disabled
    - Auto-promotion disabled until an operator enables it
    - OpenCode is the default coordinator adapter with model `gpt-5.4`
    - Validation commands restricted to `mix compile` and `mix test`
    - Operator HTTP surface enabled on `localhost:4010`
    - Coordinator expected to run separately from the app
    - Workspace writes isolated to `/workspaces`

    ## Agent Auth

    Put provider keys only in `.env.reverb`, for example:

    - `OPENCODE_API_KEY`
    - `OPENAI_API_KEY`
    - `ANTHROPIC_API_KEY`
    - `GEMINI_API_KEY`
    - `GH_TOKEN`

    The generated compose file loads `.env.reverb` with `env_file` so these keys
    are available to the coordinator container without hardcoding them into the
    compose YAML.

    If you authenticate OpenCode through the TUI using ChatGPT Plus/Pro instead
    of an API key, OpenCode stores credentials in `~/.local/share/opencode/auth.json`.
    Mount that directory into the coordinator container at
    `/root/.local/share/opencode` so the in-container `opencode` process can reuse
    the same login.

    ## Optional Rewrite Path

    Run `mix reverb.install --patch-config` if you want the installer to append
    `import_config "reverb.exs"` to your main `config/config.exs` automatically.
    """
  end
end
