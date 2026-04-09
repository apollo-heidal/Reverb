defmodule Reverb.GitTest do
  use ExUnit.Case, async: true

  alias Reverb.{Git, Tasks.Task}

  setup do
    original = Application.get_env(:reverb, Reverb.Git, [])
    original_workspaces = Application.get_env(:reverb, Reverb.Workspaces, [])

    on_exit(fn ->
      Application.put_env(:reverb, Reverb.Git, original)
      Application.put_env(:reverb, Reverb.Workspaces, original_workspaces)
    end)

    :ok
  end

  test "task_branch derives a coordinator branch" do
    task = %Task{
      id: Ecto.UUID.generate(),
      body: "Fix payment timeout",
      subject: "payments.checkout"
    }

    branch = Git.task_branch(task)
    assert String.starts_with?(branch, "reverb/task-")
    assert String.contains?(branch, "payments-checkout")
  end

  test "protected branches are rejected" do
    Application.put_env(:reverb, Reverb.Git, protected_branches: ["main", "stable"])

    assert {:error, {:protected_branch, "main"}} = Git.ensure_branch_allowed("main")
    assert :ok = Git.ensure_branch_allowed("reverb/task-123")
  end

  test "checkout_conflict_path/1 extracts conflicting worktree path" do
    output =
      "fatal: 'reverb/task-abc' is already checked out at '/workspaces/reverb/task-abc'"

    assert {:ok, "/workspaces/reverb/task-abc"} = Git.checkout_conflict_path(output)
    assert :error = Git.checkout_conflict_path("fatal: unrelated error")
  end

  test "merge_branch_into_base/1 merges a validated task branch into the base branch" do
    repo_root = Path.join(System.tmp_dir!(), "reverb-git-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_root)

    on_exit(fn -> File.rm_rf(repo_root) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: repo_root, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["config", "user.name", "Reverb Test"], cd: repo_root, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["config", "user.email", "reverb-test@example.invalid"], cd: repo_root, stderr_to_stdout: true)

    file_path = Path.join(repo_root, "feature.txt")
    File.write!(file_path, "base\n")
    assert {_, 0} = System.cmd("git", ["add", "feature.txt"], cd: repo_root, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "base"], cd: repo_root, stderr_to_stdout: true)

    assert {_, 0} = System.cmd("git", ["checkout", "-b", "reverb/task-123"], cd: repo_root, stderr_to_stdout: true)
    File.write!(file_path, "base\nmerged\n")
    assert {_, 0} = System.cmd("git", ["add", "feature.txt"], cd: repo_root, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["commit", "-m", "task change"], cd: repo_root, stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["checkout", "main"], cd: repo_root, stderr_to_stdout: true)

    Application.put_env(:reverb, Reverb.Workspaces, repo_root: repo_root, source_ref: "HEAD")

    assert {:ok, %{base_branch: "main", pushed: false}} = Git.merge_branch_into_base("reverb/task-123")
    assert File.read!(file_path) =~ "merged"
  end
end
