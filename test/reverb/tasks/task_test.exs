defmodule Reverb.Tasks.TaskTest do
  use Reverb.DataCase, async: true

  alias Reverb.Tasks.Task

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Task.changeset(%Task{}, %{"body" => "Fix this bug"})
      assert changeset.valid?
    end

    test "invalid without body" do
      changeset = Task.changeset(%Task{}, %{})
      refute changeset.valid?
      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates body length" do
      changeset = Task.changeset(%Task{}, %{"body" => String.duplicate("x", 16_001)})
      refute changeset.valid?
    end

    test "accepts all optional fields" do
      changeset =
        Task.changeset(%Task{}, %{
          "body" => "task",
          "category" => "error",
          "source_id" => "prod@server",
          "source_kind" => "signal",
          "subject" => "payments.checkout",
          "fingerprint" => "abc123",
          "error_count" => 5,
          "attempt_count" => 1,
          "priority" => 10,
          "severity" => "high",
          "status" => "todo",
          "state" => "running",
          "validation_status" => "running",
          "remote_status" => "push_pending",
          "assigned_agent" => "agent-1",
          "branch_name" => "reverb/task-123",
          "workspace_path" => "/tmp/reverb/task-123",
          "steering_notes" => "focus on coverage",
          "last_error" => "last failure",
          "done_note" => "fixed",
          "metadata" => %{"key" => "val"}
        })

      assert changeset.valid?
    end
  end

  describe "status_values/0" do
    test "returns expected statuses" do
      assert Task.status_values() == [:new, :todo, :worked_on, :done]
    end
  end

  describe "severity_values/0" do
    test "returns expected severities" do
      assert Task.severity_values() == [:critical, :high, :medium, :low]
    end
  end

  describe "state_values/0" do
    test "returns coordinator states" do
      assert Task.state_values() == [
               :pending,
               :claimed,
               :running,
               :validating,
               :awaiting_approval,
               :stable,
               :failed,
               :shelved,
               :cancelled
              ]
    end
  end
end
