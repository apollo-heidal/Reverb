defmodule Mix.Tasks.Reverb.Quickstart do
  use Mix.Task

  alias Reverb.Quickstart.Config
  alias Reverb.Quickstart.Template

  @shortdoc "Generates a new Reverb quickstart project"

  @switches [
    force: :boolean,
    target: :string,
    project_name: :string,
    app_name: :string,
    module: :string,
    topic_hash: :string,
    reverb_erlang_cookie: :string,
    initial_admin_email: :string,
    initial_admin_password: :string,
    secret_key_base: :string,
    token_signing_secret: :string,
    app_port: :string,
    opencode_port: :string,
    workspace_root_host_path: :string,
    bind_mount_suffix: :string,
    reverb_image: :string,
    quickstart_prod_image: :string
  ]

  @impl true
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)
    target = Keyword.get(opts, :target) || raise ArgumentError, "missing required option --target"

    if opts[:force] do
      File.rm_rf!(Path.expand(target))
    end

    config = Config.build!(opts)
    Template.render!(config)
    initialize_git_repo!(Path.join(config.target, "app"))

    Mix.shell().info("generated quickstart project at #{config.target}")
    Mix.shell().info("app module: #{config.app_module}")
    Mix.shell().info("topic hash: #{config.topic_hash}")
  end

  defp initialize_git_repo!(app_root) do
    run_git!(app_root, ["init"])
    run_git!(app_root, ["branch", "-M", "main"])
    run_git!(app_root, ["add", "-A"])

    env = [
      {"GIT_AUTHOR_NAME", "Reverb Quickstart"},
      {"GIT_AUTHOR_EMAIL", "quickstart@reverb.invalid"},
      {"GIT_COMMITTER_NAME", "Reverb Quickstart"},
      {"GIT_COMMITTER_EMAIL", "quickstart@reverb.invalid"}
    ]

    {_, 0} = System.cmd("git", ["commit", "-m", "Initial quickstart app"], cd: app_root, env: env, stderr_to_stdout: true)
  end

  defp run_git!(cwd, args) do
    {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
