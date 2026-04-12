defmodule Reverb.Agent.Worker do
  @moduledoc """
  Executes a single task attempt inside a coordinator-managed workspace.
  """

  alias Reverb.{Git, Promotion, Runs, Tasks, Validation}

  def perform(%Tasks.Task{} = task, agent_id, config)
      when is_binary(agent_id) and is_map(config) do
    case Reverb.Workspaces.Pool.checkout(task, branch: Git.task_branch(task)) do
      {:ok, slot} ->
        try do
          with {:ok, run} <- create_run(task, agent_id, slot, config),
               {:ok, task} <-
                 Tasks.mark_running(task, %{
                   assigned_agent: agent_id,
                   branch_name: slot.branch,
                   workspace_path: slot.path,
                   current_run_id: run.id
                 }),
               {:ok, run} <- Runs.mark_running(run),
               {:ok, result} <- execute_agent(task, slot.path, config),
               :ok <- Git.commit_all(slot.path, commit_message(task)),
               {:ok, run} <-
                 Runs.mark_validating(run, %{
                   agent_output: result.output,
                   metadata: run_metadata(run, %{
                     "agent_session_id" => Map.get(result, :session_id),
                     "agent_command" => result.command,
                     "agent_args" => result.args,
                     "agent_exit_code" => result.exit_code
                   })
                 }),
               {:ok, task} <- Tasks.mark_validating(task),
               {:ok, validation_output} <- Validation.run(slot.path, validation_opts(task)),
               {:ok, outcome} <- promotion_outcome(task, slot.branch),
               {:ok, run} <-
                 Runs.mark_finished(run, :succeeded, %{
                   validation_output: validation_output,
                   pr_url: outcome.pr_url,
                   remote_ref: outcome.remote_ref,
                   metadata:
                     run_metadata(run, %{
                       "promotion_action" => outcome.action,
                       "remote_status" => outcome.remote_status,
                       "pr_url" => outcome.pr_url,
                       "remote_ref" => outcome.remote_ref
                     })
                 }),
               {:ok, task} <- finalize_task(task, outcome) do
            %{
              status: :succeeded,
              task_id: task.id,
              run_id: run.id,
              subject: subject_for(task),
              agent_id: agent_id,
              branch_name: slot.branch,
              workspace_path: slot.path,
              output: result.output,
              validation_output: validation_output,
              pr_url: outcome.pr_url,
              remote_status: outcome.remote_status
            }
          else
            {:error, {:exit_code, _code, result}} ->
              fail(task, agent_id, result.output, :retryable_infra)

            {:error, :timeout} ->
              fail(task, agent_id, "agent execution timed out", :retryable_infra)

            {:error, %{combined_output: output}} ->
              fail(task, agent_id, output, :deterministic_validation)

            {:error, reason} ->
              fail(task, agent_id, inspect(reason), :retryable_infra)
          end
        after
          _ = Reverb.Workspaces.Pool.checkin_by_path(slot.path)
        end

      {:error, reason} ->
        fail(task, agent_id, inspect(reason), :retryable_infra)
    end
  end

  def approve(%Tasks.Task{} = task) do
    with {:ok, outcome} <- Promotion.approve(task),
         {:ok, task} <- finalize_task(task, outcome) do
      if run = Runs.latest_for_task(task.id) do
        _ =
          Runs.update_run(run, %{
            pr_url: outcome.pr_url,
            remote_ref: outcome.remote_ref,
            metadata:
              run_metadata(run, %{
                "promotion_action" => :approved,
                "remote_status" => outcome.remote_status,
                "pr_url" => outcome.pr_url,
                "remote_ref" => outcome.remote_ref
              })
          })
      end

      {:ok, task}
    end
  end

  defp execute_agent(task, cwd, config) do
    prompt = build_task_prompt(task, cwd)

    Reverb.Agent.CLI.run(prompt,
      adapter: Map.get(config, :agent_adapter, :opencode),
      command: config.agent_command,
      args: config.agent_args,
      model: Map.get(config, :agent_model),
      cwd: cwd,
      timeout_ms: config.task_timeout_ms,
      env: [
        {"HOME", System.get_env("HOME") || "/tmp"},
        {"PATH", System.get_env("PATH") || "/usr/bin:/bin"}
      ]
    )
  end

  defp create_run(task, agent_id, slot, config) do
    Runs.create_run(%{
      task_id: task.id,
      assigned_agent: agent_id,
      branch_name: slot.branch,
      workspace_path: slot.path,
      status: :queued,
      metadata: %{
        "source_node" => task.source_id,
        "adapter" => Map.get(config, :agent_adapter, :opencode),
        "model" => Map.get(config, :agent_model),
        "workspace_path" => slot.path,
        "validation_commands" => validation_commands_for(task)
      }
    })
  end

  defp finalize_task(task, %{action: :mark_stable} = outcome) do
    Tasks.mark_stable(task, %{
      remote_status: outcome.remote_status,
      done_note: outcome.done_note
    })
  end

  defp finalize_task(task, %{action: :mark_awaiting_approval} = outcome) do
    Tasks.mark_awaiting_approval(task, %{
      remote_status: outcome.remote_status,
      done_note: outcome.done_note
    })
  end

  defp fail(task, agent_id, reason, failure_class) do
    if current_run = current_run(task) do
      _ =
        Runs.mark_finished(current_run, :failed, %{
          last_error: reason,
          metadata:
            run_metadata(current_run, %{
              "failure_class" => failure_class,
              "last_error" => reason
            })
        })
    end

    _ = Tasks.mark_failed(task, reason, %{assigned_agent: agent_id, failure_class: failure_class})

    %{
      status: :failed,
      task_id: task.id,
      run_id: task.current_run_id,
      subject: subject_for(task),
      agent_id: agent_id,
      error: reason
    }
  end

  defp build_task_prompt(task, _workspace_path) do
    case task.steering_notes do
      notes when is_binary(notes) and notes != "" ->
        """
        #{task.body}

        Steering notes:
        #{notes}
        """

      _ ->
        task.body
    end
  end

  defp commit_message(task) do
    "reverb: #{String.slice(task.body, 0, 72)}"
  end

  defp current_run(task) do
    case task.current_run_id do
      nil -> nil
      id -> Runs.get_run(id)
    end
  end

  defp subject_for(task) do
    task.subject || task.fingerprint || "task:#{task.id}"
  end

  defp validation_opts(task) do
    opts = [env: validation_env()]

    case validation_commands_for(task) do
      nil -> opts
      commands -> Keyword.put(opts, :commands, commands)
    end
  end

  defp validation_commands_for(task) do
    task_validation_commands(task) || default_validation_commands()
  end

  defp task_validation_commands(task) do
    case metadata_value(task, "validation_commands") || metadata_value(task, "validation") do
      nil -> nil
      [] -> nil
      commands -> commands
    end
  end

  defp default_validation_commands do
    Application.get_env(:reverb, Reverb.Validation, [])
    |> Keyword.get(:commands, [])
  end

  defp validation_env do
    [
      {"MIX_ENV", "test"},
      {"REVERB_MODE", "disabled"},
      {"REVERB_START_PUBSUB", "false"},
      {"REVERB_AGENT_ENABLED", "false"}
    ]
  end

  defp metadata_value(task, key) do
    case task.metadata || %{} do
      %{^key => value} -> value
      _ -> nil
    end
  end

  defp run_metadata(run, attrs) do
    Map.merge(run.metadata || %{}, Map.new(attrs, fn {key, value} -> {to_string(key), value} end))
  end

  defp promotion_outcome(task, branch) do
    if Git.yolo_mode?() do
      with {:ok, %{base_branch: base_branch, pushed: pushed?}} <- Git.merge_branch_into_base(branch) do
        {:ok,
         %{
           action: :mark_stable,
           done_note: yolo_success_note(base_branch, pushed?),
           pr_url: nil,
           remote_ref: base_branch,
           remote_status: if(pushed?, do: :merged, else: :local_only)
         }}
      end
    else
      Promotion.prepare(task)
    end
  end

  defp yolo_success_note(base_branch, true),
    do: "Validated locally, merged into #{base_branch}, and pushed to origin/#{base_branch}"

  defp yolo_success_note(base_branch, false),
    do: "Validated locally and merged into #{base_branch}"

  defp format_list(values) when is_list(values), do: Enum.join(values, ", ")
  defp format_list(nil), do: "n/a"
  defp format_list(value), do: to_string(value)
end
