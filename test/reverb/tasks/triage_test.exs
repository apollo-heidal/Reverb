defmodule Reverb.Tasks.TriageTest do
  use Reverb.DataCase, async: false

  alias Reverb.{Message, Tasks.Triage}

  describe "process/1" do
    test "creates a task from a new message" do
      msg = Message.new(:error, "crash in payment handler", source: "Payments.process/2")
      assert {:ok, task} = Triage.process(msg)

      assert task.body == "crash in payment handler"
      assert task.category == "error"
      assert task.status == :new
      assert is_binary(task.fingerprint)
    end

    test "deduplicates by fingerprint" do
      msg1 = Message.new(:error, "repeated error", source: "MyMod.func/1")
      msg2 = Message.new(:error, "repeated error", source: "MyMod.func/1")

      {:ok, task1} = Triage.process(msg1)
      {:ok, task2} = Triage.process(msg2)

      assert task1.id == task2.id
      assert task2.error_count == 2
    end

    test "different errors create different tasks" do
      msg1 = Message.new(:error, "error A", source: "ModA")
      msg2 = Message.new(:error, "error B", source: "ModB")

      {:ok, task1} = Triage.process(msg1)
      {:ok, task2} = Triage.process(msg2)

      assert task1.id != task2.id
    end

    test "sets source_id from node" do
      msg = Message.new(:warning, "slow query")
      {:ok, task} = Triage.process(msg)

      assert task.source_id == to_string(node())
    end

    test "captain requests always create distinct tasks" do
      msg1 = Message.new(:manual, "build a leaderboard", metadata: %{"source_kind" => "captain"})
      msg2 = Message.new(:manual, "build a leaderboard", metadata: %{source_kind: "captain"})

      {:ok, task1} = Triage.process(msg1)
      {:ok, task2} = Triage.process(msg2)

      assert task1.id != task2.id
      assert task1.source_kind == "captain"
      assert task2.source_kind == "captain"
    end
  end
end
