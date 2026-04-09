defmodule Reverb.Tasks.TasksTest do
  use Reverb.DataCase, async: false

  alias Reverb.Tasks

  defp create_task(attrs \\ %{}) do
    base = %{body: "test task #{System.unique_integer([:positive])}"}
    {:ok, task} = Tasks.create_task(Map.merge(base, attrs))
    task
  end

  describe "create_task/1" do
    test "creates a task with valid attrs" do
      assert {:ok, task} = Tasks.create_task(%{body: "Fix the bug"})
      assert task.body == "Fix the bug"
      assert task.status == :new
      assert task.severity == :medium
      assert task.error_count == 1
    end

    test "fails without body" do
      assert {:error, changeset} = Tasks.create_task(%{})
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "upsert_by_fingerprint/2" do
    test "creates new task when fingerprint is new" do
      assert {:ok, task} = Tasks.upsert_by_fingerprint("fp-new", %{body: "new error"})
      assert task.fingerprint == "fp-new"
      assert task.error_count == 1
    end

    test "increments error_count when fingerprint exists" do
      {:ok, task1} = Tasks.upsert_by_fingerprint("fp-dup", %{body: "dup error"})
      {:ok, task2} = Tasks.upsert_by_fingerprint("fp-dup", %{body: "dup error again"})

      assert task2.id == task1.id
      assert task2.error_count == 2
    end

    test "does not increment for :done tasks" do
      {:ok, task} = Tasks.upsert_by_fingerprint("fp-done", %{body: "old error"})
      Tasks.update_status(task.id, :done)

      {:ok, new_task} = Tasks.upsert_by_fingerprint("fp-done", %{body: "same error"})
      assert new_task.id != task.id
      assert new_task.error_count == 1
    end
  end

  describe "list_by_status/2" do
    test "returns tasks with given status" do
      task = create_task()
      Tasks.update_status(task.id, :todo)

      todos = Tasks.list_by_status(:todo)
      assert Enum.any?(todos, fn t -> t.id == task.id end)
    end

    test "respects limit" do
      for _ <- 1..5, do: create_task()
      assert length(Tasks.list_by_status(:new, limit: 2)) <= 2
    end
  end

  describe "update_status/2" do
    test "updates status" do
      task = create_task()
      assert {:ok, updated} = Tasks.update_status(task.id, :worked_on)
      assert updated.status == :worked_on
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} = Tasks.update_status(Ecto.UUID.generate(), :done)
    end
  end

  describe "get_task/1" do
    test "returns task by id" do
      task = create_task()
      assert Tasks.get_task(task.id).id == task.id
    end

    test "returns nil for non-existent id" do
      assert Tasks.get_task(Ecto.UUID.generate()) == nil
    end
  end

  describe "list_eligible/1" do
    test "includes pending/failed and expired in-flight tasks" do
      now = DateTime.utc_now()
      pending = create_task(%{status: :todo, state: :pending})
      failed = create_task(%{status: :todo, state: :failed})

      expired_validating =
        create_task(%{
          status: :worked_on,
          state: :validating,
          lease_expires_at: DateTime.add(now, -10, :second)
        })

      claimed_no_lease =
        create_task(%{
          status: :worked_on,
          state: :claimed,
          lease_expires_at: nil
        })

      fresh_running =
        create_task(%{
          status: :worked_on,
          state: :running,
          lease_expires_at: DateTime.add(now, 600, :second)
        })

      done_validating =
        create_task(%{
          status: :done,
          state: :validating,
          lease_expires_at: DateTime.add(now, -10, :second)
        })

      eligible_ids =
        Tasks.list_eligible(limit: 20, now: now)
        |> Enum.map(& &1.id)

      assert pending.id in eligible_ids
      assert failed.id in eligible_ids
      assert expired_validating.id in eligible_ids
      assert claimed_no_lease.id in eligible_ids
      refute fresh_running.id in eligible_ids
      refute done_validating.id in eligible_ids
    end

    test "prioritizes captain tasks ahead of automated work" do
      now = DateTime.utc_now()

      automated =
        create_task(%{
          body: "automated",
          status: :todo,
          state: :pending,
          priority: 0
        })

      captain =
        create_task(%{
          body: "captain",
          status: :todo,
          state: :pending,
          priority: 100,
          source_kind: "captain"
        })

      [first | _rest] = Tasks.list_eligible(limit: 10, now: now)
      assert first.id == captain.id
      assert first.id != automated.id
    end
  end

  describe "list_recent/1" do
    test "filters by source_kind" do
      captain = create_task(%{body: "captain task", source_kind: "captain"})
      _signal = create_task(%{body: "signal task", source_kind: "signal"})

      tasks = Tasks.list_recent(source_kind: "captain")

      assert Enum.map(tasks, & &1.id) == [captain.id]
    end
  end

  describe "recover_inflight_tasks/1" do
    test "requeues in-flight tasks and clears lease/assignment" do
      stale =
        create_task(%{
          status: :worked_on,
          state: :validating,
          validation_status: :running,
          lease_expires_at: DateTime.utc_now(),
          assigned_agent: "agent-1",
          current_run_id: Ecto.UUID.generate(),
          workspace_path: "/tmp/reverb/test-workspace"
        })

      untouched = create_task(%{status: :done, state: :stable})

      assert 1 == Tasks.recover_inflight_tasks()

      recovered = Tasks.get_task(stale.id)
      assert recovered.state == :pending
      assert recovered.validation_status == :pending
      assert recovered.assigned_agent == nil
      assert recovered.current_run_id == nil
      assert recovered.workspace_path == nil
      assert recovered.lease_expires_at == nil

      assert Tasks.get_task(untouched.id).state == :stable
    end
  end

  describe "transition guardrails" do
    test "rejects invalid task state transitions" do
      task = create_task(%{status: :todo, state: :pending})

      assert {:error, {:invalid_transition, :pending, :stable}} = Tasks.mark_stable(task)
    end

    test "shelves tasks after retry budget exhaustion" do
      original_scheduler = Application.get_env(:reverb, Reverb.Scheduler, [])
      Application.put_env(:reverb, Reverb.Scheduler, max_attempts_per_task: 1, retry_backoff_ms: 100)

      on_exit(fn ->
        Application.put_env(:reverb, Reverb.Scheduler, original_scheduler)
      end)

      task = create_task(%{status: :worked_on, state: :failed, attempt_count: 1})

      assert {:ok, task} = Tasks.mark_failed(task, "still broken", %{failure_class: :deterministic_validation})
      assert task.state == :shelved
      assert task.status == :done
      assert task.done_note =~ "Shelved after"
    end

    test "enforces forward-only remote status progression" do
      task = create_task(%{status: :done, state: :stable, remote_status: :pr_opened})

      assert {:error, {:invalid_remote_status_transition, :pr_opened, :pushed}} =
               Tasks.mark_remote_status(task, :pushed)
    end
  end
end
