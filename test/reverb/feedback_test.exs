defmodule Reverb.FeedbackTest do
  use Reverb.DataCase, async: false

  alias Reverb.{Feedback, Runs, Tasks}

  test "ingests deploy feedback by branch name" do
    {:ok, task} =
      Tasks.create_task(%{
        body: "ship the fix",
        status: :done,
        state: :stable,
        branch_name: "reverb/task-123",
        remote_status: :pr_opened
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        branch_name: task.branch_name,
        status: :succeeded,
        metadata: %{}
      })

    assert {:ok, %{task: updated_task, run: updated_run}} =
             Feedback.ingest_event(%{type: :deployed, branch_name: task.branch_name})

    assert updated_task.remote_status == :deployed
    assert updated_task.done_note =~ "Deployed at"
    assert updated_run.id == run.id
    assert updated_run.metadata["last_feedback_event"] == "deployed"
  end
end
