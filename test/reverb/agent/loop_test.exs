defmodule Reverb.Agent.LoopTest do
  use Reverb.DataCase, async: false

  alias Reverb.{Agent.Loop, Tasks}

  @fake_agent Path.expand("test/support/fixtures/fake_agent.sh")
  @failing_agent Path.expand("test/support/fixtures/failing_agent.sh")

  defp start_loop(overrides \\ []) do
    workspace_root =
      Path.join(System.tmp_dir!(), "reverb-loop-test-#{System.unique_integer([:positive])}")

    base = [
      enabled: true,
      boot_delay_ms: 100,
      cooldown_ms: 100,
      idle_rotation_ms: 100,
      task_timeout_ms: 10_000,
      max_consecutive_failures: 2,
      backoff_base_ms: 200,
      backoff_max_ms: 1_000,
      project_root: File.cwd!(),
      agent_command: @fake_agent,
      agent_args: []
    ]

    config = Keyword.merge(base, overrides)
    Application.put_env(:reverb, Reverb.Agent, config)

    Application.put_env(:reverb, Reverb.Workspaces,
      root: workspace_root,
      repo_root: File.cwd!(),
      source_ref: "HEAD",
      reclaim_on_boot: true
    )

    start_supervised!(Loop)
  end

  describe "disabled mode" do
    test "starts in disabled state" do
      Application.put_env(:reverb, Reverb.Agent, enabled: false)
      start_supervised!(Loop)

      status = Loop.status()
      assert status.alive == true
      assert status.status == :disabled
    end

    test "starts in paused state when configured" do
      Application.put_env(:reverb, Reverb.Agent, enabled: true, start_paused: true)
      start_supervised!(Loop)

      status = Loop.status()
      assert status.alive == true
      assert status.status == :paused
    end
  end

  describe "status/0" do
    test "returns expected fields" do
      start_loop()
      status = Loop.status()

      assert Map.has_key?(status, :alive)
      assert Map.has_key?(status, :status)
      assert Map.has_key?(status, :current_task_id)
      assert Map.has_key?(status, :consecutive_failures)
      assert Map.has_key?(status, :uptime_seconds)
    end
  end

  describe "pause/resume" do
    test "pause sets status to paused" do
      start_loop(boot_delay_ms: 60_000)
      assert :ok = Loop.pause()
      assert %{status: :paused} = Loop.status()
    end

    test "resume after pause" do
      start_loop(boot_delay_ms: 60_000)
      :ok = Loop.pause()
      :ok = Loop.resume()
      assert Loop.status().status in [:idle, :booting, :running]
    end
  end

  describe "task processing" do
    test "completes a task" do
      {:ok, task} = Tasks.create_task(%{body: "test task", status: :todo})
      start_loop()

      Process.sleep(2_000)

      updated = Tasks.get_task(task.id)
      assert updated.status == :done
    end
  end

  describe "circuit breaker" do
    test "enters backoff after failures" do
      {:ok, _} = Tasks.create_task(%{body: "will fail 1", status: :todo})
      {:ok, _} = Tasks.create_task(%{body: "will fail 2", status: :todo})
      {:ok, _} = Tasks.create_task(%{body: "will fail 3", status: :todo})

      start_loop(agent_command: @failing_agent, max_consecutive_failures: 2)

      Process.sleep(2_000)

      status = Loop.status()
      assert status.consecutive_failures >= 2
    end
  end

  describe "boot recovery" do
    test "requeues in-flight tasks on startup" do
      {:ok, task} =
        Tasks.create_task(%{
          body: "stale validating task",
          status: :worked_on,
          state: :validating,
          validation_status: :running,
          assigned_agent: "agent-1",
          current_run_id: Ecto.UUID.generate(),
          workspace_path: "/tmp/reverb/stale"
        })

      start_loop(boot_delay_ms: 60_000, recover_inflight_on_boot: true)

      Process.sleep(150)

      updated = Tasks.get_task(task.id)
      assert updated.state == :pending
      assert updated.validation_status == :pending
      assert updated.assigned_agent == nil
      assert updated.current_run_id == nil
      assert updated.workspace_path == nil
    end
  end
end
