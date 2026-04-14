defmodule Reverb.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    mode = Application.get_env(:reverb, :mode, :disabled)
    Logger.info("[Reverb] Starting in #{mode} mode")

    children = base_children(mode) ++ mode_children(mode)

    opts = [strategy: :one_for_one, name: Reverb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp base_children(:receiver) do
    pubsub = Application.get_env(:reverb, :pubsub_name)
    start_pubsub? = Application.get_env(:reverb, :start_pubsub, false)

    pubsub_child =
      if pubsub && start_pubsub? do
        Logger.info("[Reverb] Starting PubSub #{inspect(pubsub)} (standalone receiver)")
        [pubsub_child_spec(pubsub)]
      else
        []
      end

    pubsub_child ++ common_children()
  end

  defp base_children(_) do
    common_children()
  end

  defp common_children do
    repo_children = if repo_configured?(), do: [Reverb.Repo], else: []

    [
      pubsub_child_spec(Reverb.LocalPubSub),
      Reverb.Runtime,
      Reverb.Claims,
      Reverb.Agent.Pool,
      Reverb.Agent.Auth
    ] ++ repo_children
  end

  defp repo_configured? do
    case Application.get_env(:reverb, Reverb.Repo) do
      nil ->
        false

      config ->
        Keyword.keyword?(config) and
          (not is_nil(config[:pool]) or not is_nil(config[:pool_size]) or not is_nil(config[:url]) or
             not is_nil(config[:database]))
    end
  end

  defp mode_children(:emitter) do
    emitter_config = Application.get_env(:reverb, Reverb.Emitter, [])

    if Keyword.get(emitter_config, :logger_handler, false) do
      Reverb.Emitter.LoggerHandler.attach()
    end

    if Keyword.get(emitter_config, :telemetry_events, []) != [] do
      Reverb.Emitter.TelemetryHandler.attach()
    end

    # Emitter has no supervised children (handlers are global)
    []
  end

  defp mode_children(:receiver) do
    agent_config = Application.get_env(:reverb, Reverb.Agent, [])
    operator_config = Application.get_env(:reverb, Reverb.Operator, [])

    receiver_children = [
      Reverb.Receiver.Guard,
      Reverb.Receiver.Listener,
      Reverb.Workspaces.Pool,
      {Task.Supervisor, name: Reverb.Agent.TaskSupervisor}
    ] ++
      if Keyword.get(operator_config, :enabled, false) do
        [Reverb.Operator.Server]
      else
        []
      end

    agent_children =
      if Keyword.get(agent_config, :enabled, false) do
        [Reverb.Agent.Loop]
      else
        []
      end

    receiver_children ++ agent_children
  end

  defp mode_children(_), do: []

  defp pubsub_child_spec(name) do
    Supervisor.child_spec({Phoenix.PubSub, name: name}, id: {:phoenix_pubsub, name})
  end
end
