defmodule Reverb.Agent.Loop do
  @moduledoc """
  Scheduler-backed coordinator loop.

  The public surface remains compatible with the original single-agent loop,
  but internally the loop now manages multiple worker slots, durable run
  records, subject claims, workspace isolation, and validation handoffs.
  """

  use GenServer
  require Logger

  alias Reverb.{Claims, Runtime, Tasks}
  alias Reverb.Agent.Worker

  @default_config %{
    enabled: false,
    start_paused: false,
    boot_delay_ms: 30_000,
    cooldown_ms: 30_000,
    idle_rotation_ms: 900_000,
    task_timeout_ms: 600_000,
    max_consecutive_failures: 3,
    backoff_base_ms: 120_000,
    backoff_max_ms: 900_000,
    agent_command: "opencode",
    agent_args: ["run", "--format", "json", "--dangerously-skip-permissions"],
    agent_model: "gpt-5.4",
    project_root: nil,
    agent_adapter: :opencode,
    max_agents: 1,
    poll_interval_ms: 5_000,
    recover_inflight_on_boot: true,
    max_attempts_per_task: 3,
    retry_backoff_ms: 30_000
  }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current agent loop status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Pauses the agent loop."
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc "Resumes the agent loop."
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc "Returns status for each worker slot."
  def agents_status do
    GenServer.call(__MODULE__, :agents_status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    ensure_dependencies_started()
    config = load_config()
    recovered_count = maybe_recover_inflight_tasks(config)

    state = %{
      status: :booting,
      current_task_id: nil,
      current_task_body: nil,
      consecutive_failures: 0,
      last_completed_at: nil,
      started_at: DateTime.utc_now(),
      rotation_index: 0,
      loop_timer_ref: nil,
      workers: init_workers(config.max_agents),
      config: config,
      recovered_inflight_count: recovered_count
    }

    cond do
      config.enabled && config.start_paused ->
        Logger.info("[Reverb.Loop] Started in paused mode")
        Runtime.scheduler_status(%{status: :paused, max_agents: config.max_agents})
        {:ok, %{state | status: :paused}}

      config.enabled ->
      Logger.info("[Reverb.Loop] Starting, first loop in #{config.boot_delay_ms}ms")
      ref = Process.send_after(self(), :loop, config.boot_delay_ms)
      Runtime.scheduler_status(%{status: :booting, max_agents: config.max_agents})
      {:ok, %{state | loop_timer_ref: ref}}

      true ->
      Logger.info("[Reverb.Loop] Started in disabled mode")
      Runtime.scheduler_status(%{status: :disabled, max_agents: config.max_agents})
      {:ok, %{state | status: :disabled}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      alive: true,
      status: state.status,
      current_task_id: state.current_task_id,
      current_task_body: state.current_task_body,
      consecutive_failures: state.consecutive_failures,
      last_completed_at: state.last_completed_at,
      rotation_index: state.rotation_index,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second),
      max_agents: state.config.max_agents,
      running_agents: count_running_workers(state),
      agents: worker_statuses(state)
    }

    {:reply, reply, state}
  end

  def handle_call(:agents_status, _from, state) do
    {:reply, worker_statuses(state), state}
  end

  def handle_call(:pause, _from, state) do
    state = cancel_timer(state, :loop_timer_ref)
    state = %{state | status: :paused}
    Logger.info("[Reverb.Loop] Paused")
    Runtime.scheduler_status(%{status: :paused})
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    if state.status == :paused do
      Logger.info("[Reverb.Loop] Resumed")
      ref = Process.send_after(self(), :loop, 0)
      Runtime.scheduler_status(%{status: :idle})
      {:reply, :ok, %{state | status: :idle, loop_timer_ref: ref}}
    else
      {:reply, {:error, :not_paused}, state}
    end
  end

  @impl true
  def handle_info(:loop, %{status: :paused} = state) do
    {:noreply, state}
  end

  def handle_info(:loop, state) do
    state = %{state | loop_timer_ref: nil}
    Claims.reap_expired()
    state = dispatch_available_workers(state)
    emit_queue_depth_metric()
    ref = Process.send_after(self(), :loop, next_delay(state))
    state = %{state | loop_timer_ref: ref}

    Runtime.scheduler_status(%{
      status: loop_status(state),
      running_agents: count_running_workers(state),
      current_task_id: state.current_task_id,
      current_task_body: state.current_task_body
    })

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    {agent_id, worker} = find_worker_by_ref(state, ref)
    Process.demonitor(ref, [:flush])

    state =
      if agent_id do
        handle_worker_result(agent_id, worker, result, state)
      else
        state
      end

    {:noreply, schedule_now(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_worker_by_ref(state, ref) do
      {nil, _worker} ->
        {:noreply, state}

      {agent_id, worker} ->
        reason = Exception.format_exit(reason)
        Logger.warning("[Reverb.Loop] Worker #{agent_id} crashed: #{reason}")
        state = fail_worker(agent_id, worker, reason, state)
        {:noreply, schedule_now(state)}
    end
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp load_config do
    app_config =
      Application.get_env(:reverb, Reverb.Agent, [])
      |> Map.new()

    scheduler_config =
      Application.get_env(:reverb, Reverb.Scheduler, [])
      |> Map.new()

    config = @default_config |> Map.merge(scheduler_config) |> Map.merge(app_config)
    %{config | project_root: config.project_root || File.cwd!()}
  end

  defp maybe_recover_inflight_tasks(config) do
    if config.recover_inflight_on_boot do
      count = Tasks.recover_inflight_tasks()

      if count > 0 do
        Logger.warning("[Reverb.Loop] Recovered #{count} in-flight tasks on boot")
        Runtime.record_event(:inflight_tasks_recovered, %{count: count})
      end

      count
    else
      0
    end
  rescue
    error ->
      Logger.warning("[Reverb.Loop] Failed to recover in-flight tasks: #{inspect(error)}")
      0
  end

  defp ensure_dependencies_started do
    ensure_pubsub_started()
    ensure_process_started(Reverb.Runtime, fn -> Reverb.Runtime.start_link() end)
    ensure_process_started(Reverb.Claims, fn -> Reverb.Claims.start_link() end)

    ensure_process_started(Reverb.Agent.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Reverb.Agent.TaskSupervisor)
    end)

    ensure_process_started(Reverb.Workspaces.Pool, fn -> Reverb.Workspaces.Pool.start_link() end)
  end

  defp ensure_pubsub_started do
    if Process.whereis(Reverb.LocalPubSub) do
      :ok
    else
      ensure_process_started(Reverb.LocalPubSubSupervisor, fn ->
        Supervisor.start_link(
          [{Phoenix.PubSub, name: Reverb.LocalPubSub}],
          strategy: :one_for_one,
          name: Reverb.LocalPubSubSupervisor
        )
      end)
    end
  end

  defp ensure_process_started(name, starter) do
    if Process.whereis(name) do
      :ok
    else
      case starter.() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(name)}: #{inspect(reason)}"
      end
    end
  end

  defp init_workers(max_agents) do
    for index <- 1..max_agents, into: %{} do
      agent_id = "agent-#{index}"

      {agent_id,
       %{
         status: :idle,
         ref: nil,
         pid: nil,
         task_id: nil,
         task_body: nil,
         started_at: nil,
         last_result: nil
       }}
    end
  end

  defp dispatch_available_workers(state) do
    idle_agents =
      state.workers
      |> Enum.filter(fn {_agent_id, worker} -> worker.status == :idle end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(idle_agents, state, fn agent_id, acc ->
      case next_schedulable_task() do
        {:ok, task} ->
          start_worker(agent_id, task, acc)

        :empty ->
          acc
      end
    end)
  end

  defp next_schedulable_task do
    Tasks.list_eligible(limit: 25)
    |> Enum.find_value(:empty, fn task ->
      subject = Tasks.subject_for(task)

      case Claims.claim(subject, subject, lease_ms()) do
        :ok -> {:ok, task}
        {:error, _} -> false
      end
    end)
  end

  defp start_worker(agent_id, task, state) do
    Logger.info("[Reverb.Loop] Dispatching #{task.id} to #{agent_id}")
    Runtime.record_event(:task_dispatched, %{task_id: task.id, agent_id: agent_id})

    :telemetry.execute(
      [:reverb, :task, :dispatched],
      %{latency_ms: max(DateTime.diff(DateTime.utc_now(), task.inserted_at, :millisecond), 0)},
      %{task_id: task.id, agent_id: agent_id}
    )

    {:ok, claimed_task} =
      Tasks.claim_task(task, %{assigned_agent: agent_id, subject: Tasks.subject_for(task)})

    Tasks.update_status(task.id, :worked_on)

    async =
      Task.Supervisor.async_nolink(Reverb.Agent.TaskSupervisor, fn ->
        Worker.perform(claimed_task, agent_id, state.config)
      end)

    worker = %{
      status: :running,
      ref: async.ref,
      pid: async.pid,
      task_id: task.id,
      task_body: task.body,
      started_at: DateTime.utc_now(),
      last_result: nil
    }

    Runtime.agent_status(agent_id, Map.drop(worker, [:ref, :pid]))

    workers = Map.put(state.workers, agent_id, worker)
    current = current_task_from_workers(workers)

    %{
      state
      | workers: workers,
        status: :running,
        current_task_id: current.id,
        current_task_body: current.body
    }
  end

  defp handle_worker_result(agent_id, worker, result, state) do
    subject = result[:subject] || task_subject(worker.task_id)
    _ = Claims.release(subject)

    {status, failures} =
      case result[:status] do
        :succeeded -> {:idle, 0}
        _ -> {:idle, state.consecutive_failures + 1}
      end

    next_status =
      if failures >= state.config.max_consecutive_failures do
        :backoff
      else
        status
      end

    Runtime.record_event(:task_completed, %{
      task_id: worker.task_id,
      agent_id: agent_id,
      status: result[:status]
    })

    Runtime.agent_status(agent_id, %{
      status: :idle,
      task_id: nil,
      task_body: nil,
      last_result: result
    })

    workers =
      Map.put(state.workers, agent_id, %{
        worker
        | status: :idle,
          ref: nil,
          pid: nil,
          task_id: nil,
          task_body: nil,
          started_at: nil,
          last_result: result
      })

    current = current_task_from_workers(workers)

    %{
      state
      | workers: workers,
        status: next_status,
        consecutive_failures: failures,
        last_completed_at: DateTime.utc_now(),
        current_task_id: current.id,
        current_task_body: current.body
    }
  end

  defp fail_worker(agent_id, worker, reason, state) do
    if task = Tasks.get_task(worker.task_id) do
      _ = Tasks.mark_failed(task, reason, %{assigned_agent: agent_id})
      _ = Claims.release(Tasks.subject_for(task))
    end

    Runtime.record_event(:worker_failed, %{
      task_id: worker.task_id,
      agent_id: agent_id,
      reason: reason
    })

    Runtime.agent_status(agent_id, %{
      status: :idle,
      task_id: nil,
      task_body: nil,
      last_result: %{status: :failed, error: reason}
    })

    workers =
      Map.put(state.workers, agent_id, %{
        worker
        | status: :idle,
          ref: nil,
          pid: nil,
          task_id: nil,
          task_body: nil,
          started_at: nil,
          last_result: %{status: :failed, error: reason}
      })

    current = current_task_from_workers(workers)
    failures = state.consecutive_failures + 1

    %{
      state
      | workers: workers,
        status: if(failures >= state.config.max_consecutive_failures, do: :backoff, else: :idle),
        consecutive_failures: failures,
        current_task_id: current.id,
        current_task_body: current.body
    }
  end

  defp current_task_from_workers(workers) do
    case Enum.find(workers, fn {_id, worker} -> worker.status == :running end) do
      nil -> %{id: nil, body: nil}
      {_id, worker} -> %{id: worker.task_id, body: worker.task_body}
    end
  end

  defp cancel_timer(state, key) do
    case Map.get(state, key) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.put(state, key, nil)
    end
  end

  defp backoff_delay(failures, config) do
    exponent = failures - config.max_consecutive_failures
    delay = config.backoff_base_ms * :math.pow(2, exponent)
    min(round(delay), config.backoff_max_ms)
  end

  defp next_delay(state) do
    cond do
      state.status == :paused ->
        state.config.poll_interval_ms

      state.status == :backoff ->
        backoff_delay(
          max(state.consecutive_failures, state.config.max_consecutive_failures),
          state.config
        )

      count_running_workers(state) == 0 ->
        state.config.poll_interval_ms

      true ->
        state.config.cooldown_ms
    end
  end

  defp schedule_now(state) do
    state = cancel_timer(state, :loop_timer_ref)
    %{state | loop_timer_ref: Process.send_after(self(), :loop, 0)}
  end

  defp worker_statuses(state) do
    Enum.map(state.workers, fn {agent_id, worker} ->
      worker
      |> Map.drop([:ref, :pid])
      |> Map.put(:agent_id, agent_id)
    end)
  end

  defp loop_status(state) do
    cond do
      state.status == :paused -> :paused
      state.status == :backoff -> :backoff
      count_running_workers(state) > 0 -> :running
      true -> :idle
    end
  end

  defp count_running_workers(state) do
    state.workers
    |> Enum.count(fn {_id, worker} -> worker.status == :running end)
  end

  defp find_worker_by_ref(state, ref) do
    Enum.find_value(state.workers, {nil, nil}, fn {agent_id, worker} ->
      if worker.ref == ref, do: {agent_id, worker}, else: false
    end)
  end

  defp task_subject(nil), do: nil

  defp task_subject(task_id) do
    case Tasks.get_task(task_id) do
      nil -> nil
      task -> Tasks.subject_for(task)
    end
  end

  defp lease_ms do
    Application.get_env(:reverb, Reverb.Scheduler, [])
    |> Keyword.get(:lease_ms, 300_000)
  end

  defp emit_queue_depth_metric do
    queue_depth = length(Tasks.list_eligible(limit: 1_000))

    :telemetry.execute(
      [:reverb, :scheduler, :queue],
      %{depth: queue_depth},
      %{}
    )
  end
end
