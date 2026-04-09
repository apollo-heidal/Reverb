defmodule Reverb.Feedback do
  @moduledoc """
  Ingests merge and deploy feedback and maps it back to Reverb tasks and runs.
  """

  import Ecto.Query, warn: false

  alias Reverb.{Repo, Runs, Runtime, Tasks}
  alias Reverb.Runs.Run
  alias Reverb.Tasks.Task

  @event_types [:merged, :deployed]

  @spec ingest_event(map()) :: {:ok, %{event: map(), run: %Run{} | nil, task: %Task{}}} | {:error, term()}
  def ingest_event(attrs) when is_map(attrs) do
    with {:ok, event} <- normalize_event(attrs),
         {:ok, task, run} <- locate_targets(event),
         {:ok, task} <- apply_task_feedback(task, event),
         {:ok, run} <- apply_run_feedback(run, event) do
      Runtime.record_event(:feedback_ingested, %{
        task_id: task.id,
        run_id: run && run.id,
        event: event.type,
        remote_status: task.remote_status
      })

      :telemetry.execute(
        [:reverb, :feedback, :ingested],
        %{count: 1},
        %{event: event.type, task_id: task.id, run_id: run && run.id}
      )

      if event.type == :deployed and run && run.finished_at do
        :telemetry.execute(
          [:reverb, :promotion, :deployed],
          %{latency_ms: max(DateTime.diff(event.at, run.finished_at, :millisecond), 0)},
          %{task_id: task.id, run_id: run.id}
        )
      end

      {:ok, %{event: event, task: task, run: run}}
    end
  end

  defp normalize_event(attrs) do
    type = normalize_type(Map.get(attrs, :type) || Map.get(attrs, "type"))

    if type in @event_types do
      {:ok,
       %{
         type: type,
         at: Map.get(attrs, :at) || Map.get(attrs, "at") || DateTime.utc_now(),
         task_id: Map.get(attrs, :task_id) || Map.get(attrs, "task_id"),
         run_id: Map.get(attrs, :run_id) || Map.get(attrs, "run_id"),
         branch_name: Map.get(attrs, :branch_name) || Map.get(attrs, "branch_name"),
         pr_url: Map.get(attrs, :pr_url) || Map.get(attrs, "pr_url"),
         metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
       }}
    else
      {:error, {:invalid_feedback_event, attrs}}
    end
  end

  defp normalize_type(type) when type in @event_types, do: type
  defp normalize_type("merged"), do: :merged
  defp normalize_type("deployed"), do: :deployed
  defp normalize_type(_), do: nil

  defp locate_targets(%{task_id: task_id, run_id: run_id}) when is_binary(task_id) do
    case Tasks.get_task(task_id) do
      %Task{} = task -> {:ok, task, run_id && Runs.get_run(run_id)}
      nil -> {:error, :task_not_found}
    end
  end

  defp locate_targets(%{branch_name: branch_name}) when is_binary(branch_name) do
    case Runs.latest_for_branch(branch_name) do
      %Run{} = run -> {:ok, Tasks.get_task!(run.task_id), run}
      nil -> locate_task_by_branch(branch_name)
    end
  end

  defp locate_targets(%{pr_url: pr_url}) when is_binary(pr_url) do
    case Runs.latest_for_pr_url(pr_url) do
      %Run{} = run -> {:ok, Tasks.get_task!(run.task_id), run}
      nil -> locate_task_by_pr_url(pr_url)
    end
  end

  defp locate_targets(_event), do: {:error, :feedback_target_not_found}

  defp locate_task_by_branch(branch_name) do
    case Repo.one(from(t in Task, where: t.branch_name == ^branch_name, order_by: [desc: t.updated_at], limit: 1)) do
      %Task{} = task -> {:ok, task, Runs.latest_for_task(task.id)}
      nil -> {:error, :feedback_target_not_found}
    end
  end

  defp locate_task_by_pr_url(pr_url) do
    case Repo.one(
           from(t in Task,
             where: fragment("?->>'pr_url' = ?", t.metadata, ^pr_url),
             order_by: [desc: t.updated_at],
             limit: 1
           )
         ) do
      %Task{} = task -> {:ok, task, Runs.latest_for_task(task.id)}
      nil -> {:error, :feedback_target_not_found}
    end
  end

  defp apply_task_feedback(%Task{} = task, event) do
    Tasks.mark_remote_status(task, event.type, %{
      done_note: note_for(event),
      metadata: Map.merge(task.metadata || %{}, event_metadata(event))
    })
  end

  defp apply_run_feedback(nil, _event), do: {:ok, nil}

  defp apply_run_feedback(%Run{} = run, event) do
    Runs.update_run(run, %{
      pr_url: event.pr_url || run.pr_url,
      remote_ref: event.branch_name || run.remote_ref,
      metadata: Map.merge(run.metadata || %{}, event_metadata(event))
    })
  end

  defp note_for(%{type: :merged, at: at}), do: "Merged at #{DateTime.to_iso8601(at)}"
  defp note_for(%{type: :deployed, at: at}), do: "Deployed at #{DateTime.to_iso8601(at)}"

  defp event_metadata(event) do
    %{
      "last_feedback_event" => Atom.to_string(event.type),
      "last_feedback_at" => DateTime.to_iso8601(event.at),
      "pr_url" => event.pr_url,
      "branch_name" => event.branch_name,
      "feedback_metadata" => event.metadata
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
