defmodule Reverb do
  @moduledoc """
  Reverb — production error reverberation for BEAM apps.

  Bridges production apps to dev-side AI agents via BEAM distribution.
  Production apps emit error messages over PubSub; a dev-side companion
  captures them, triages into tasks, and queues them for an agent loop.

  ## Usage

  Add to your app as a dependency:

      {:reverb, path: "../reverb"}

  Configure in prod:

      config :reverb,
        mode: :emitter,
        topic_hash: "my-app-prod",
        pubsub_name: MyApp.PubSub

  Configure in dev:

      config :reverb,
        mode: :receiver,
        topic_hash: "my-app-prod",
        pubsub_name: MyApp.PubSub

  ## Manual Emission

      Reverb.emit(:error, "Payment processing failed", metadata: %{order_id: 123})
      Reverb.emit(:warning, "Slow query detected", source: "MyApp.Repo")
      Reverb.emit(:manual, "Review this user flow")
  """

  alias Reverb.{Message, Emitter.Broadcaster}

  @doc """
  Emits a Reverb message from the current node.

  Only works in `:emitter` mode. No-op otherwise.

  ## Options

  - `:source` — origin (e.g., "MyModule.my_func/2:42")
  - `:stacktrace` — formatted stacktrace string
  - `:metadata` — arbitrary map of context
  - `:severity` — `:critical | :high | :medium | :low`
  """
  def emit(kind, message, opts \\ [])

  def emit(kind, message, opts) when kind in [:error, :warning, :manual, :telemetry] do
    if Application.get_env(:reverb, :mode) == :emitter do
      msg = Message.new(kind, message, opts)
      Broadcaster.broadcast(msg)
    else
      :ok
    end
  end

  @doc "Returns the agent loop status. Only works in `:receiver` mode."
  def status do
    if Process.whereis(Reverb.Agent.Loop) do
      Reverb.Agent.Loop.status()
    else
      %{alive: false, status: :disabled}
    end
  end

  @doc "Pauses the agent loop."
  def pause do
    if Process.whereis(Reverb.Agent.Loop),
      do: Reverb.Agent.Loop.pause(),
      else: {:error, :not_running}
  end

  @doc "Resumes the agent loop."
  def resume do
    if Process.whereis(Reverb.Agent.Loop),
      do: Reverb.Agent.Loop.resume(),
      else: {:error, :not_running}
  end

  @doc "Lists recent tasks for steering and inspection."
  def tasks(opts \\ []) do
    Reverb.Tasks.list_recent(opts)
  end

  @doc "Returns a task by id."
  def get_task(id) do
    Reverb.Tasks.get_task(id)
  end

  @doc "Lists recent runs."
  def runs(opts \\ []) do
    Reverb.Runs.list_recent(opts)
  end

  @doc "Returns a run by id."
  def get_run(id) do
    Reverb.Runs.get_run(id)
  end

  @doc "Creates a manual task."
  def create_manual_task(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:source_kind, "manual")
      |> Map.put_new(:category, "manual")

    Reverb.Tasks.create_task(attrs)
  end

  @doc "Updates a task's priority."
  def reprioritize_task(id, priority) when is_integer(priority) do
    with %Reverb.Tasks.Task{} = task <- Reverb.Tasks.get_task(id) do
      Reverb.Tasks.update_task(task, %{priority: priority})
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Updates steering notes for a task."
  def update_task_notes(id, notes) when is_binary(notes) do
    with %Reverb.Tasks.Task{} = task <- Reverb.Tasks.get_task(id) do
      Reverb.Tasks.update_task(task, %{steering_notes: notes})
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Retries a failed or stalled task by resetting it to the queue."
  def retry_task(id) do
    with %Reverb.Tasks.Task{} = task <- Reverb.Tasks.get_task(id) do
      Reverb.Tasks.reset_for_retry(task)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Cancels a task."
  def cancel_task(id) do
    with %Reverb.Tasks.Task{} = task <- Reverb.Tasks.get_task(id) do
      Reverb.Tasks.cancel_task(task)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Approves a validated task for remote push/PR promotion."
  def approve_task(id) do
    with %Reverb.Tasks.Task{} = task <- Reverb.Tasks.get_task(id) do
      Reverb.Agent.Worker.approve(task)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Ingests merge or deploy feedback for an existing cycle." 
  def ingest_feedback(attrs) when is_map(attrs) do
    Reverb.Feedback.ingest_event(attrs)
  end

  @doc "Returns worker slot status."
  def agents_status do
    if Process.whereis(Reverb.Agent.Loop),
      do: Reverb.Agent.Loop.agents_status(),
      else: []
  end
end
