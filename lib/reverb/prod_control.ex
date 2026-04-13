defmodule Reverb.ProdControl do
  @moduledoc """
  Fixed, coordinator-owned BEAM RPC surface for prod-side apply actions.

  This is intentionally small. Agents never select arbitrary MFA calls or shell
  commands inside the prod app. Reverb only invokes a generated control module
  with fixed functions, and mutating functions remain disabled when YOLO mode is
  off.
  """

  @restart_prefixes ["assets/", "config/", "lib/", "priv/"]
  @restart_files ["mix.exs", "mix.lock"]

  defmodule Plan do
    @moduledoc false
    defstruct files: [], migrate?: false, restart?: false
  end

  @spec plan([String.t()]) :: %Plan{}
  def plan(files) when is_list(files) do
    files = Enum.map(files, &to_string/1) |> Enum.uniq()
    migrate? = Enum.any?(files, &String.starts_with?(&1, "priv/repo/migrations/"))

    restart? =
      migrate? or
        Enum.any?(files, fn file ->
          file in @restart_files or Enum.any?(@restart_prefixes, &String.starts_with?(file, &1))
        end)

    %Plan{files: files, migrate?: migrate?, restart?: restart?}
  end

  @spec apply_plan(%Plan{}) :: {:ok, %Plan{}} | {:error, term()}
  def apply_plan(%Plan{migrate?: false, restart?: false} = plan), do: {:ok, plan}

  def apply_plan(%Plan{} = plan) do
    with :ok <- maybe_migrate(plan),
         :ok <- maybe_restart(plan),
         :ok <- wait_until_available() do
      {:ok, plan}
    end
  end

  def apply_plan(_plan), do: {:error, :invalid_plan}

  @spec enabled?() :: boolean()
  def enabled? do
    match?(module when is_atom(module), control_module())
  end

  @spec status() :: {:ok, term()} | {:error, term()}
  def status do
    rpc_call(:status, [], timeout_ms())
  end

  defp maybe_migrate(%Plan{migrate?: false}), do: :ok
  defp maybe_migrate(%Plan{}), do: expect_ok(rpc_call(:migrate, [], timeout_ms()))

  defp maybe_restart(%Plan{restart?: false}), do: :ok
  defp maybe_restart(%Plan{}), do: expect_ok(rpc_call(:restart_app, [], timeout_ms()))

  defp wait_until_available do
    started = System.monotonic_time(:millisecond)

    do_wait_until_available(started)
  end

  defp do_wait_until_available(started_at) do
    case status() do
      {:ok, _} ->
        :ok

      {:error, _reason} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        if elapsed >= timeout_ms() do
          {:error, :prod_control_timeout}
        else
          Process.sleep(retry_ms())
          do_wait_until_available(started_at)
        end
    end
  end

  defp expect_ok({:ok, :ok}), do: :ok
  defp expect_ok({:ok, _value}), do: :ok
  defp expect_ok({:error, _} = error), do: error

  defp rpc_call(function, args, timeout) do
    with module when is_atom(module) <- control_module() || {:error, :control_module_not_configured},
         prod_node when is_atom(prod_node) <- prod_node() || {:error, :prod_node_not_configured},
         :ok <- ensure_connected(prod_node) do
      case :rpc.call(prod_node, module, function, args, timeout) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        value -> {:ok, value}
      end
    else
      false -> {:error, :node_unreachable}
      {:error, _} = error -> error
    end
  end

  defp prod_node do
    Application.get_env(:reverb, Reverb.Receiver, [])
    |> Keyword.get(:prod_node)
  end

  defp control_module do
    Application.get_env(:reverb, Reverb.ProdControl, [])
    |> Keyword.get(:module)
  end

  defp timeout_ms do
    Application.get_env(:reverb, Reverb.ProdControl, [])
    |> Keyword.get(:timeout_ms, 120_000)
  end

  defp retry_ms do
    Application.get_env(:reverb, Reverb.ProdControl, [])
    |> Keyword.get(:retry_ms, 2_000)
  end

  defp ensure_connected(prod_node) do
    case Node.ping(prod_node) do
      :pong -> :ok
      :pang -> if(Node.connect(prod_node) and Node.ping(prod_node) == :pong, do: :ok, else: {:error, :node_unreachable})
    end
  end
end
