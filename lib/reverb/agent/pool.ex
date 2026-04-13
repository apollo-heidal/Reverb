defmodule Reverb.Agent.Pool do
  @moduledoc """
  ETS-backed adapter health tracking and fallback-chain resolution.

  Each adapter (:opencode, :codex, :claude, :hermes) has an ETS entry tracking:
    - availability (CLI present and not rate-limited)
    - consecutive failures (reset on success)
    - rate-limit expiry time

  The pool resolves the next healthy adapter/model pair from a configurable
  fallback chain, skipping adapters that are unhealthy or rate-limited.

  ## Fallback chain configuration

  The chain is built from runtime config:

    REVERB_AGENT_ADAPTER=opencode        (primary adapter)
    REVERB_AGENT_MODEL=openai/gpt-5.4    (primary model)
    REVERB_FALLBACK_MODELS=anthropic/claude-sonnet-4-20250514,google/gemini-2.5-flash

  The primary adapter is tried first with its primary model. If it fails with
  a retryable error, the next model in the fallback chain is tried (same adapter).
  If all models on the primary adapter fail, the next available adapter is tried
  with its models, and so on.

  This mirrors the tiered fallback from the Apollo language router:
  adapter → model → degrade to next adapter.
  """

  use GenServer
  require Logger

  @table __MODULE__
  @adapters [:opencode, :codex, :claude, :hermes]
  @health_check_interval_ms 60_000
  @max_consecutive_failures 3
  @failure_cooldown_ms 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc "Returns the full fallback chain as [{adapter, model}] pairs."
  def fallback_chain do
    GenServer.call(__MODULE__, :fallback_chain)
  end

  @doc "Returns the next healthy {adapter, model} pair after the given one."
  def next_after({adapter, model}) do
    GenServer.call(__MODULE__, {:next_after, adapter, model})
  end

  @doc "Returns the primary {adapter, model} from config."
  def primary do
    GenServer.call(__MODULE__, :primary)
  end

  @doc "Records a successful execution for the given adapter."
  def mark_ok(adapter) do
    GenServer.cast(__MODULE__, {:mark_ok, adapter})
  end

  @doc "Records a failure for the given adapter. Returns :ok or {:error, :shelve}."
  def mark_failed(adapter, reason) do
    GenServer.call(__MODULE__, {:mark_failed, adapter, reason})
  end

  @doc "Marks an adapter as rate-limited for the given number of seconds."
  def mark_rate_limited(adapter, wait_seconds) do
    GenServer.cast(__MODULE__, {:mark_rate_limited, adapter, wait_seconds})
  end

  @doc "Returns whether the given adapter is currently available."
  def available?(adapter) do
    case :ets.lookup(@table, adapter) do
      [{^adapter, entry}] ->
        is_nil(entry.rate_limited_until) or
          DateTime.compare(entry.rate_limited_until, DateTime.utc_now()) == :lt

      [] ->
        false
    end
  end

  @doc "Returns the current health status of all adapters."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Resets all health state (useful for testing)."
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def adapter_healthy?(adapter) do
    case :ets.lookup(@table, adapter) do
      [{^adapter, entry}] ->
        entry.consecutive_failures < @max_consecutive_failures and
          (is_nil(entry.rate_limited_until) or
             DateTime.compare(entry.rate_limited_until, DateTime.utc_now()) == :lt)

      [] ->
        false
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :protected, :named_table, keypos: 1])

    for adapter <- @adapters do
      :ets.insert(table, {adapter, initial_entry(adapter)})
    end

    chain = build_chain()

    if function_exported?(Process, :send_after, 2) do
      Process.send_after(self(), :health_check, @health_check_interval_ms)
    end

    {:ok, %{table: table, chain: chain, primary: hd(chain)}}
  end

  @impl true
  def handle_call(:fallback_chain, _from, state) do
    {:reply, state.chain, state}
  end

  def handle_call({:next_after, adapter, model}, _from, state) do
    result =
      state.chain
      |> Enum.drop_while(fn {a, m} -> a != adapter or m != model end)
      |> Enum.drop(1)
      |> Enum.find(fn {a, _m} -> adapter_healthy?(a) end)

    {:reply, result, state}
  end

  def handle_call(:primary, _from, state) do
    {:reply, state.primary, state}
  end

  def handle_call({:mark_failed, adapter, reason}, _from, state) do
    entry =
      case :ets.lookup(@table, adapter) do
        [{^adapter, entry}] -> entry
        [] -> initial_entry(adapter)
      end

    new_count = entry.consecutive_failures + 1

    new_entry = %{entry | consecutive_failures: new_count, last_failure: reason, last_failure_at: DateTime.utc_now()}
    :ets.insert(@table, {adapter, new_entry})

    if new_count >= @max_consecutive_failures do
      Logger.warning(
        "[Reverb.Pool] #{adapter} marked unhealthy after #{new_count} consecutive failures: #{inspect(reason)}"
      )
    end

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    entries =
      for adapter <- @adapters do
        case :ets.lookup(@table, adapter) do
          [{^adapter, entry}] -> {adapter, entry}
          [] -> {adapter, initial_entry(adapter)}
        end
      end

    {:reply, %{adapters: entries, chain: state.chain}, state}
  end

  def handle_call(:reset, _from, state) do
    for adapter <- @adapters do
      :ets.insert(@table, {adapter, initial_entry(adapter)})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:mark_ok, adapter}, state) do
    case :ets.lookup(@table, adapter) do
      [{^adapter, entry}] ->
        :ets.insert(@table, {adapter, %{entry | consecutive_failures: 0, last_failure: nil}})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:mark_rate_limited, adapter, wait_seconds}, state) do
    until = DateTime.add(DateTime.utc_now(), wait_seconds, :second)

    case :ets.lookup(@table, adapter) do
      [{^adapter, entry}] ->
        :ets.insert(@table, {adapter, %{entry | rate_limited_until: until}})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    now = DateTime.utc_now()

    for adapter <- @adapters do
      case :ets.lookup(@table, adapter) do
        [{^adapter, entry}] when entry.consecutive_failures >= @max_consecutive_failures ->
          if entry.last_failure_at do
            elapsed = DateTime.diff(now, entry.last_failure_at, :millisecond)

            if elapsed > @failure_cooldown_ms do
              Logger.info("[Reverb.Pool] Re-enabling #{adapter} after cooldown")
              :ets.insert(@table, {adapter, %{entry | consecutive_failures: 0}})
            end
          end

        _ ->
          :ok
      end
    end

    Process.send_after(self(), :health_check, @health_check_interval_ms)
    {:noreply, state}
  end

  defp initial_entry(adapter) do
    %{
      consecutive_failures: 0,
      rate_limited_until: nil,
      last_failure: nil,
      last_failure_at: nil,
      cli_present: cli_present?(adapter)
    }
  end

  defp cli_present?(:opencode), do: System.find_executable("opencode") != nil
  defp cli_present?(:codex), do: System.find_executable("codex") != nil
  defp cli_present?(:claude), do: System.find_executable("claude") != nil
  defp cli_present?(:hermes), do: System.find_executable("hermes") != nil
  defp cli_present?(_), do: false

  defp build_chain do
    primary_adapter = get_config(:agent_adapter, :opencode)
    primary_model = get_config(:agent_model, "gpt-5.4")

    fallback_models =
      Application.get_env(:reverb, Reverb.Agent, [])
      |> Keyword.get(:fallback_models, [])

    fallback_adapters =
      Application.get_env(:reverb, Reverb.Agent, [])
      |> Keyword.get(:fallback_adapters, [])
      |> Enum.filter(&(&1 != primary_adapter))

    chain = [{primary_adapter, primary_model}]

    chain =
      chain ++
        for model <- fallback_models do
          {primary_adapter, model}
        end

    chain =
      chain ++
        for adapter <- fallback_adapters,
            model <- [primary_model | fallback_models] do
          {adapter, model}
        end

    chain
  end

  defp get_config(key, default) do
    Application.get_env(:reverb, Reverb.Agent, [])
    |> Keyword.get(key, default)
  end
end
