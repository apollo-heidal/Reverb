import Config

split_env_list = fn
  nil -> nil
  value -> String.split(value, ";;", trim: true)
end

parse_bool = fn
  value when is_binary(value) ->
    case String.downcase(String.trim(value)) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      _ -> false
    end

  _ ->
    false
end

if config_env() == :prod do
  config :reverb, Reverb.Repo,
    url: System.get_env("REVERB_DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("REVERB_POOL_SIZE") || "5")

  # Mode override (emitter, receiver, disabled)
  if mode = System.get_env("REVERB_MODE") do
    config :reverb, mode: String.to_atom(mode)
  end

  # Standalone receiver: start PubSub in this VM (not needed when embedded in a host app)
  if System.get_env("REVERB_START_PUBSUB") == "true" do
    config :reverb, start_pubsub: true
  end

  # PubSub name override (must match the host app's PubSub for cross-node :pg messaging)
  if pubsub = System.get_env("REVERB_PUBSUB_NAME") do
    config :reverb, pubsub_name: String.to_atom("Elixir.#{pubsub}")
  end

  # Topic hash override (both emitter and receiver must agree on this)
  if topic = System.get_env("REVERB_TOPIC_HASH") do
    config :reverb, topic_hash: topic
  end

  if yolo_mode = System.get_env("REVERB_YOLO_MODE") do
    config :reverb, yolo_mode: parse_bool.(yolo_mode)
  end

  # Receiver: which prod node to connect to and which nodes to allow
  if prod_node = System.get_env("REVERB_PROD_NODE") do
    allowed =
      (System.get_env("REVERB_ALLOWED_NODES") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom(String.trim(&1)))

    config :reverb, Reverb.Receiver,
      prod_node: String.to_atom(prod_node),
      allowed_nodes: allowed
  end

  # Agent: project_root tells Claude CLI where to work
  if project_root = System.get_env("REVERB_PROJECT_ROOT") do
    config :reverb, Reverb.Agent, project_root: project_root
  end

  agent_overrides =
    []
    |> then(fn overrides ->
      case System.get_env("REVERB_AGENT_ENABLED") do
        nil ->
          overrides

        value ->
          enabled =
            case String.downcase(value) do
              "1" -> true
              "true" -> true
              "yes" -> true
              _ -> false
            end

          Keyword.put(overrides, :enabled, enabled)
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_AGENT_ADAPTER") do
        nil -> overrides
        value -> Keyword.put(overrides, :agent_adapter, String.to_atom(value))
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_AGENT_COMMAND") do
        nil -> overrides
        value -> Keyword.put(overrides, :agent_command, value)
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_AGENT_MODEL") do
        nil -> overrides
        value -> Keyword.put(overrides, :agent_model, value)
      end
    end)
    |> then(fn overrides ->
      case split_env_list.(System.get_env("REVERB_AGENT_ARGS")) do
        nil -> overrides
        value -> Keyword.put(overrides, :agent_args, value)
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_AGENT_MAX_AGENTS") do
        nil -> overrides
        value -> Keyword.put(overrides, :max_agents, String.to_integer(value))
      end
    end)

  if agent_overrides != [] do
    config :reverb, Reverb.Agent, agent_overrides
  end

  scheduler_overrides =
    []
    |> then(fn overrides ->
      case System.get_env("REVERB_SCHED_START_PAUSED") do
        nil -> overrides
        value -> Keyword.put(overrides, :start_paused, parse_bool.(value))
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_SCHED_RECOVER_INFLIGHT_ON_BOOT") do
        nil -> overrides
        value -> Keyword.put(overrides, :recover_inflight_on_boot, parse_bool.(value))
      end
    end)

  if scheduler_overrides != [] do
    config :reverb, Reverb.Scheduler, scheduler_overrides
  end

  workspace_overrides =
    []
    |> then(fn overrides ->
      case System.get_env("REVERB_WORKSPACE_ROOT") do
        nil -> overrides
        value -> Keyword.put(overrides, :root, value)
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_WORKSPACE_REPO_ROOT") do
        nil -> overrides
        value -> Keyword.put(overrides, :repo_root, value)
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_WORKSPACE_SOURCE_REF") do
        nil -> overrides
        value -> Keyword.put(overrides, :source_ref, value)
      end
    end)

  if workspace_overrides != [] do
    config :reverb, Reverb.Workspaces, workspace_overrides
  end

  git_overrides =
    []
    |> then(fn overrides ->
      case System.get_env("REVERB_GIT_AUTO_PROMOTE") do
        nil -> overrides
        value -> Keyword.put(overrides, :auto_promote, parse_bool.(value))
      end
    end)

  if git_overrides != [] do
    config :reverb, Reverb.Git, git_overrides
  end

  operator_overrides =
    []
    |> then(fn overrides ->
      case System.get_env("REVERB_OPERATOR_ENABLED") do
        nil -> overrides
        value -> Keyword.put(overrides, :enabled, parse_bool.(value))
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_OPERATOR_PORT") do
        nil -> overrides
        value -> Keyword.put(overrides, :port, String.to_integer(value))
      end
    end)

  if operator_overrides != [] do
    config :reverb, Reverb.Operator, operator_overrides
  end

  prod_control_overrides =
    []
    |> then(fn overrides ->
      case System.get_env("REVERB_CONTROL_MODULE") do
        nil -> overrides
        value -> Keyword.put(overrides, :module, value |> String.split(".") |> Module.concat())
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_CONTROL_TIMEOUT_MS") do
        nil -> overrides
        value -> Keyword.put(overrides, :timeout_ms, String.to_integer(value))
      end
    end)
    |> then(fn overrides ->
      case System.get_env("REVERB_CONTROL_RETRY_MS") do
        nil -> overrides
        value -> Keyword.put(overrides, :retry_ms, String.to_integer(value))
      end
    end)

  if prod_control_overrides != [] do
    config :reverb, Reverb.ProdControl, prod_control_overrides
  end

  if commands = split_env_list.(System.get_env("REVERB_VALIDATION_COMMANDS")) do
    config :reverb, Reverb.Validation, commands: commands
  end
end
