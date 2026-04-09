defmodule Reverb.Tasks do
  @moduledoc """
  Context module for managing Reverb tasks.

  Provides CRUD operations, status queries, and fingerprint-based upsert
  for error deduplication.
  """

  import Ecto.Query, warn: false
  alias Reverb.Repo
  alias Reverb.Tasks.Task

  @active_statuses [:new, :todo, :worked_on]
  @queue_states [:pending, :failed]
  @recoverable_inflight_states [:claimed, :running, :validating]
  @state_transitions %{
    pending: MapSet.new([:claimed, :cancelled]),
    claimed: MapSet.new([:running, :failed, :cancelled, :pending]),
    running: MapSet.new([:validating, :failed, :cancelled, :pending]),
    validating: MapSet.new([:awaiting_approval, :stable, :failed, :shelved, :cancelled]),
    awaiting_approval: MapSet.new([:stable, :shelved, :cancelled]),
    stable: MapSet.new([]),
    failed: MapSet.new([:pending, :shelved, :cancelled]),
    shelved: MapSet.new([:pending, :cancelled]),
    cancelled: MapSet.new([:pending])
  }
  @remote_status_order [:local_only, :push_pending, :pushed, :pr_opened, :merged, :deployed]

  def status_values, do: Task.status_values()
  def severity_values, do: Task.severity_values()
  def state_values, do: Task.state_values()

  def max_attempts_per_task do
    Application.get_env(:reverb, Reverb.Scheduler, [])
    |> Keyword.get(:max_attempts_per_task, 3)
  end

  def retry_backoff_ms do
    Application.get_env(:reverb, Reverb.Scheduler, [])
    |> Keyword.get(:retry_backoff_ms, 30_000)
  end

  def subject_for(%Task{} = task) do
    task.subject || task.fingerprint || "task:#{task.id}"
  end

  @doc "Creates a new task."
  def create_task(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a task or increments error_count if a task with the same fingerprint
  already exists in an active status (:new, :todo, :worked_on).
  """
  def upsert_by_fingerprint(fingerprint, attrs) when is_binary(fingerprint) do
    active_statuses = [:new, :todo, :worked_on]

    case Repo.one(
           from(t in Task,
             where: t.fingerprint == ^fingerprint and t.status in ^active_statuses,
             limit: 1
           )
         ) do
      nil ->
        attrs = attrs |> normalize_attrs() |> Map.put("fingerprint", fingerprint)
        create_task(attrs)

      existing ->
        existing
        |> Ecto.Changeset.change(%{error_count: existing.error_count + 1})
        |> Repo.update()
    end
  end

  @doc "Lists tasks currently eligible for scheduling."
  def list_eligible(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    max_attempts = max_attempts_per_task()
    source_kind = Keyword.get(opts, :source_kind)

    Task
    |> where([t], t.status in ^@active_statuses)
    |> where(
      [t],
      t.state in ^@queue_states or
        (t.state in ^@recoverable_inflight_states and
           (is_nil(t.lease_expires_at) or t.lease_expires_at < ^now))
    )
    |> where([t], is_nil(t.lease_expires_at) or t.lease_expires_at < ^now)
    |> where([t], t.attempt_count < ^max_attempts)
    |> maybe_filter_source_kind(source_kind)
    |> order_by(
      [t],
      asc: fragment("CASE WHEN ? = 'captain' THEN 0 ELSE 1 END", t.source_kind),
      asc: t.priority,
      desc: t.severity,
      asc: t.inserted_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Requeues in-flight tasks (claimed/running/validating) back to `:pending`.

  Useful on coordinator boot after an unexpected shutdown.
  """
  def recover_inflight_tasks(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    recover_all? = Keyword.get(opts, :recover_all, true)

    query =
      Task
      |> where([t], t.status in ^@active_statuses)
      |> where([t], t.state in ^@recoverable_inflight_states)

    query =
      if recover_all? do
        query
      else
        from(t in query, where: is_nil(t.lease_expires_at) or t.lease_expires_at < ^now)
      end

    {count, _} =
      Repo.update_all(query,
        set: [
          state: :pending,
          validation_status: :pending,
          lease_expires_at: nil,
          assigned_agent: nil,
          current_run_id: nil,
          workspace_path: nil,
          updated_at: now
        ]
      )

    count
  end

  @doc "Lists recent tasks."
  def list_recent(opts \\ []) do
    since_minutes = Keyword.get(opts, :since_minutes)
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)
    state = Keyword.get(opts, :state)
    source_kind = Keyword.get(opts, :source_kind)

    base =
      Task
      |> order_by([t], desc: t.inserted_at)
      |> limit(^limit)

    base =
      if since_minutes && since_minutes > 0 do
        since = DateTime.add(DateTime.utc_now(), -since_minutes * 60, :second)
        from(t in base, where: t.inserted_at >= ^since)
      else
        base
      end

    base =
      if status && status in Task.status_values() do
        from(t in base, where: t.status == ^status)
      else
        base
      end

    base =
      if state && state in Task.state_values() do
        from(t in base, where: t.state == ^state)
      else
        base
      end

    base = maybe_filter_source_kind(base, source_kind)

    Repo.all(base)
  end

  @doc "Lists tasks by status."
  def list_by_status(status, opts \\ []) when status in [:new, :todo, :worked_on, :done] do
    limit = Keyword.get(opts, :limit, 50)

    Task
    |> where([t], t.status == ^status)
    |> order_by([t], desc: t.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Updates the status of a task."
  def update_status(id, status) when status in [:new, :todo, :worked_on, :done] do
    case Repo.get(Task, id) do
      nil -> {:error, :not_found}
      task -> task |> Ecto.Changeset.change(%{status: status}) |> Repo.update()
    end
  end

  def update_status(_, _), do: {:error, :invalid_status}

  @doc "Claims a task for an agent lease."
  def claim_task(%Task{} = task, attrs \\ %{}) do
    now = DateTime.utc_now()

    lease_ms =
      Application.get_env(:reverb, Reverb.Scheduler, []) |> Keyword.get(:lease_ms, 300_000)

    expires_at = DateTime.add(now, div(lease_ms, 1000), :second)

    with :ok <- ensure_attempt_budget(task) do
      transition_task(
        task,
        :claimed,
        attrs
        |> normalize_attrs()
        |> Map.merge(%{
          "lease_expires_at" => expires_at,
          "attempt_count" => task.attempt_count + 1
        })
      )
    end
  end

  @doc "Marks a task as running."
  def mark_running(%Task{} = task, attrs \\ %{}) do
    transition_task(task, :running, normalize_attrs(attrs))
  end

  @doc "Marks a task as validating."
  def mark_validating(%Task{} = task, attrs \\ %{}) do
    transition_task(task, :validating, Map.merge(normalize_attrs(attrs), %{"validation_status" => :running}))
  end

  @doc "Marks a validated task as awaiting human approval before promotion."
  def mark_awaiting_approval(%Task{} = task, attrs \\ %{}) do
    transition_task(
      task,
      :awaiting_approval,
      attrs
      |> normalize_attrs()
      |> Map.merge(terminal_cleanup_attrs())
      |> Map.merge(%{
        "status" => :worked_on,
        "validation_status" => :passed,
        "remote_status" => :push_pending
      })
    )
  end

  @doc "Marks a task as stable and done."
  def mark_stable(%Task{} = task, attrs \\ %{}) do
    transition_task(
      task,
      :stable,
      attrs
      |> normalize_attrs()
      |> Map.merge(terminal_cleanup_attrs())
      |> Map.merge(%{
        "status" => :done,
        "validation_status" => :passed
      })
    )
  end

  @doc "Marks a task as failed."
  def mark_failed(%Task{} = task, reason, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    failure_class = normalize_failure_class(attrs["failure_class"])
    reason_text = reason |> to_string() |> String.slice(0, 8_000)

    if shelve?(task, failure_class) do
      shelve_task(task, reason_text, Map.delete(attrs, "failure_class"))
    else
      :telemetry.execute(
        [:reverb, :task, :retry_scheduled],
        %{count: 1},
        %{task_id: task.id, attempt_count: task.attempt_count, failure_class: failure_class}
      )

      transition_task(
        task,
        :failed,
        attrs
        |> Map.delete("failure_class")
        |> Map.merge(worker_cleanup_attrs(retry_at()))
        |> Map.merge(%{
          "status" => :worked_on,
          "validation_status" => validation_status_for(failure_class),
          "last_error" => reason_text
        })
      )
    end
  end

  @doc "Shelves a task after retry exhaustion or deterministic failure."
  def shelve_task(%Task{} = task, reason, attrs \\ %{}) do
    reason_text = reason |> to_string() |> String.slice(0, 8_000)

    :telemetry.execute(
      [:reverb, :task, :shelved],
      %{count: 1},
      %{task_id: task.id, attempt_count: task.attempt_count}
    )

    transition_task(
      task,
      :shelved,
      attrs
      |> normalize_attrs()
      |> Map.merge(terminal_cleanup_attrs())
      |> Map.merge(%{
        "status" => :done,
        "validation_status" => :failed,
        "last_error" => reason_text,
        "done_note" => shelved_note(task)
      })
      |> merge_metadata(%{
        "terminal_reason" => reason_text,
        "operator_note" => shelved_note(task)
      })
    )
  end

  @doc "Updates remote promotion state with forward-only progression."
  def mark_remote_status(%Task{} = task, remote_status, attrs \\ %{}) do
    if remote_status in Task.remote_status_values() do
      with :ok <- ensure_remote_status_transition(task.remote_status, remote_status) do
        update_task(task, Map.put(normalize_attrs(attrs), "remote_status", remote_status))
      end
    else
      {:error, {:invalid_remote_status, remote_status}}
    end
  end

  @doc "Resets a task for retry."
  def reset_for_retry(%Task{} = task) do
    transition_task(task, :pending, %{
      status: retry_status(task),
      validation_status: :pending,
      remote_status: :local_only,
      lease_expires_at: nil,
      assigned_agent: nil,
      current_run_id: nil,
      workspace_path: nil,
      last_error: nil,
      done_note: nil,
      attempt_count: 0
    })
  end

  @doc "Cancels a task."
  def cancel_task(%Task{} = task) do
    transition_task(task, :cancelled, %{
      status: :done,
      done_note: "Cancelled by operator"
    } |> Map.merge(terminal_cleanup_attrs()))
  end

  @doc "Gets a single task by id."
  def get_task(id) do
    Repo.get(Task, id)
  end

  @doc "Gets a single task by id, raises if not found."
  def get_task!(id) do
    Repo.get!(Task, id)
  end

  @doc "Updates a task with the given attributes."
  def update_task(%Task{} = task, attrs) when is_map(attrs) do
    task
    |> Task.changeset(normalize_attrs(attrs))
    |> Repo.update()
  end

  defp transition_task(%Task{} = task, to_state, attrs) when is_map(attrs) do
    with :ok <- ensure_transition(task.state, to_state) do
      update_task(task, Map.put(normalize_attrs(attrs), "state", to_state))
    end
  end

  defp ensure_transition(from_state, to_state) when from_state == to_state, do: :ok

  defp ensure_transition(from_state, to_state) do
    case Map.fetch(@state_transitions, from_state) do
      {:ok, allowed} ->
        if MapSet.member?(allowed, to_state) do
          :ok
        else
          {:error, {:invalid_transition, from_state, to_state}}
        end

      :error ->
        {:error, {:invalid_transition, from_state, to_state}}
    end
  end

  defp ensure_attempt_budget(%Task{} = task) do
    if task.attempt_count < max_attempts_per_task() do
      :ok
    else
      {:error, :attempt_budget_exhausted}
    end
  end

  defp ensure_remote_status_transition(from, to) when from == to, do: :ok

  defp ensure_remote_status_transition(from, to) do
    if remote_status_index(to) >= remote_status_index(from) do
      :ok
    else
      {:error, {:invalid_remote_status_transition, from, to}}
    end
  end

  defp remote_status_index(status) do
    Enum.find_index(@remote_status_order, &(&1 == status)) || -1
  end

  defp normalize_failure_class(nil), do: :retryable_infra
  defp normalize_failure_class(value) when is_atom(value), do: value

  defp normalize_failure_class(value) when is_binary(value) do
    case value do
      "deterministic_validation" -> :deterministic_validation
      "validation_failed" -> :validation_failed
      "permanent" -> :permanent
      _ -> :retryable_infra
    end
  end

  defp validation_status_for(:deterministic_validation), do: :failed
  defp validation_status_for(:validation_failed), do: :failed
  defp validation_status_for(_failure_class), do: :pending

  defp shelve?(%Task{} = task, failure_class) do
    failure_class == :permanent or task.attempt_count >= max_attempts_per_task()
  end

  defp retry_at do
    DateTime.add(DateTime.utc_now(), div(retry_backoff_ms(), 1000), :second)
  end

  defp terminal_cleanup_attrs do
    %{
      "lease_expires_at" => nil,
      "assigned_agent" => nil,
      "current_run_id" => nil,
      "workspace_path" => nil
    }
  end

  defp worker_cleanup_attrs(lease_expires_at) do
    terminal_cleanup_attrs()
    |> Map.put("lease_expires_at", lease_expires_at)
  end

  defp shelved_note(task) do
    "Shelved after #{task.attempt_count} attempts. Review the last failure and requeue manually if needed."
  end

  defp retry_status(%Task{status: :done}), do: :todo
  defp retry_status(%Task{status: status}) when status in @active_statuses, do: status
  defp retry_status(_task), do: :todo

  defp merge_metadata(attrs, extra_metadata) do
    metadata = Map.get(attrs, "metadata", %{}) |> Map.merge(extra_metadata)
    Map.put(attrs, "metadata", metadata)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {to_string(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end

  defp maybe_filter_source_kind(query, nil), do: query

  defp maybe_filter_source_kind(query, source_kind) when is_binary(source_kind) do
    from(t in query, where: t.source_kind == ^source_kind)
  end

  defp maybe_filter_source_kind(query, _source_kind), do: query
end
