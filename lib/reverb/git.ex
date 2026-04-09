defmodule Reverb.Git do
  @moduledoc """
  Coordinator-owned git boundary.

  Agents operate inside coordinator-managed workspaces, but all branch and
  remote decisions are enforced here.
  """

  require Logger

  alias Reverb.Tasks.Task
  alias Reverb.Workspaces.PathSafety

  @default_commit_message "reverb: autonomous change"

  def git_available? do
    not is_nil(System.find_executable("git"))
  end

  def task_branch(%Task{} = task) do
    explicit_branch(task) ||
      "reverb/task-#{String.slice(task.id || Ecto.UUID.generate(), 0, 8)}-#{slug(task.subject || task.body)}"
  end

  def prepare_workspace(%Task{} = task, opts) do
    with true <- git_available?() || {:error, :git_not_available},
         repo_root when is_binary(repo_root) <-
           repo_root() || {:error, :repo_root_not_configured},
         path when is_binary(path) <-
            Keyword.get(opts, :path) || {:error, :workspace_path_required},
         branch when is_binary(branch) <- Keyword.get(opts, :branch, task_branch(task)),
         :ok <- ensure_branch_allowed(branch),
         :ok <- sync_repo_root(repo_root),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- prune_worktrees(repo_root),
         :ok <- remove_existing_worktree(path, repo_root),
         :ok <- add_worktree(repo_root, branch, path) do
      {:ok, %{path: path, branch: branch}}
    else
      {output, code} when is_binary(output) ->
        {:error, {:git_failed, code, String.trim(output)}}

      {:error, _} = error ->
        error

      false ->
        {:error, :git_not_available}

      other ->
        {:error, other}
    end
  end

  def cleanup_workspace(path) when is_binary(path) do
    case repo_root() do
      nil ->
        File.rm_rf(path)
        :ok

      repo_root ->
        if File.exists?(path) do
          case System.cmd("git", ["worktree", "remove", "--force", path],
                 cd: repo_root,
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              :ok

            {output, code} ->
              if ignorable_worktree_remove_error?(output) do
                :ok
              else
                Logger.warning(
                  "[Reverb.Git] failed to remove worktree #{path} (#{code}): #{String.trim(output)}"
                )

                :ok
              end
          end
        end

        File.rm_rf(path)
        _ = prune_worktrees(repo_root)
        :ok
    end
  end

  @doc false
  def checkout_conflict_path(output) when is_binary(output) do
    case Regex.run(~r/is already checked out at ['"]([^'"]+)['"]/, output,
           capture: :all_but_first
         ) do
      [path] -> {:ok, path}
      _ -> :error
    end
  end

  def prune_worktrees do
    case repo_root() do
      nil -> :ok
      root -> prune_worktrees(root)
    end
  end

  def status(path) when is_binary(path) do
    run_git(path, ["status", "--short"])
  end

  def commit_all(path, message \\ @default_commit_message) when is_binary(path) do
    with :ok <- run_git_ok(path, ["add", "-A"]),
         :ok <-
           run_git_ok(path, [
             "-c",
             "user.name=Reverb",
             "-c",
             "user.email=reverb@noreply.invalid",
             "commit",
             "--allow-empty",
             "-m",
             message
           ]) do
      :ok
    end
  end

  def push_branch(branch) when is_binary(branch) do
    with :ok <- ensure_remote_push_enabled(),
         :ok <- ensure_branch_allowed(branch),
         repo_root when is_binary(repo_root) <-
           repo_root() || {:error, :repo_root_not_configured},
         :ok <- run_git_ok(repo_root, ["push", remote_name(), branch]) do
      :ok
    end
  end

  def yolo_mode?, do: Application.get_env(:reverb, :yolo_mode, false)

  def base_branch do
    with repo_root when is_binary(repo_root) <- repo_root() || {:error, :repo_root_not_configured},
         {:ok, branch} <- run_git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"]),
         branch when is_binary(branch) and branch != "HEAD" <- String.trim(branch) do
      branch
    else
      _ -> source_ref()
    end
  end

  def merge_branch_into_base(branch) when is_binary(branch) do
    with true <- git_available?() || {:error, :git_not_available},
         repo_root when is_binary(repo_root) <- repo_root() || {:error, :repo_root_not_configured},
         :ok <- sync_repo_root(repo_root),
         base_branch when is_binary(base_branch) <- base_branch(),
         :ok <- run_git_ok(repo_root, ["checkout", base_branch]),
         :ok <-
            run_git_ok(repo_root, [
             "-c",
             "user.name=Reverb",
             "-c",
             "user.email=reverb@noreply.invalid",
             "merge",
             "--no-ff",
             "--no-edit",
             branch
           ]) do
      {:ok, %{base_branch: base_branch, pushed: push_base_branch_if_available(repo_root, base_branch) == :ok}}
    end
  end

  def open_or_update_pr(branch, title, body) when is_binary(branch) do
    with :ok <- ensure_remote_push_enabled(),
         true <- System.find_executable("gh") != nil || {:error, :gh_not_available},
          :ok <- ensure_branch_allowed(branch) do
      case System.cmd("gh", ["pr", "create", "--head", branch, "--title", title, "--body", body],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, String.trim(output)}

        {output, code} ->
          case existing_pr_url(branch) do
            {:ok, pr_url} -> {:ok, pr_url}
            :error -> {:error, {:gh_failed, code, String.trim(output)}}
          end
      end
    else
      false -> {:error, :gh_not_available}
      {:error, _} = error -> error
    end
  end

  def ensure_branch_allowed(branch) when is_binary(branch) do
    protected =
      Application.get_env(:reverb, Reverb.Git, [])
      |> Keyword.get(:protected_branches, ["main", "master"])

    if branch in protected do
      {:error, {:protected_branch, branch}}
    else
      :ok
    end
  end

  defp explicit_branch(%Task{branch_name: branch}) when is_binary(branch) and branch != "",
    do: branch

  defp explicit_branch(_task), do: nil

  defp ensure_remote_push_enabled do
    config = Application.get_env(:reverb, Reverb.Git, [])

    if Keyword.get(config, :remote_enabled, false) and Keyword.get(config, :push_enabled, false) do
      :ok
    else
      {:error, :remote_push_disabled}
    end
  end

  defp push_base_branch_if_available(repo_root, base_branch) do
    case System.cmd("git", ["remote", "get-url", remote_name()], cd: repo_root, stderr_to_stdout: true) do
      {_, 0} -> run_git_ok(repo_root, ["push", remote_name(), base_branch])
      _ -> :noop
    end
  end

  defp sync_repo_root(repo_root) do
    case {remote_available?(repo_root), clean_repo_root?(repo_root)} do
      {true, true} ->
        with :ok <- run_git_ok(repo_root, ["fetch", remote_name(), "--prune"]),
             branch when is_binary(branch) <- current_branch(repo_root),
             true <- branch != "HEAD",
             true <- remote_branch_exists?(repo_root, branch) || :no_remote_branch,
             :ok <- run_git_ok(repo_root, ["checkout", branch]),
             :ok <- run_git_ok(repo_root, ["rebase", "#{remote_name()}/#{branch}"]) do
          :ok
        else
          :no_remote_branch -> :ok
          false -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp current_branch(repo_root) do
    case run_git(repo_root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> String.trim(branch)
      _ -> "HEAD"
    end
  end

  defp remote_branch_exists?(repo_root, branch) do
    case System.cmd(
           "git",
           ["show-ref", "--verify", "--quiet", "refs/remotes/#{remote_name()}/#{branch}"],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp remote_available?(repo_root) do
    case System.cmd("git", ["remote", "get-url", remote_name()], cd: repo_root, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp clean_repo_root?(repo_root) do
    case run_git(repo_root, ["status", "--porcelain"]) do
      {:ok, ""} -> true
      {:ok, _output} -> false
      _ -> false
    end
  end

  defp remove_existing_worktree(path, repo_root) do
    if File.exists?(path) do
      cleanup_workspace(path)
    else
      prune_worktrees(repo_root)
    end
  end

  defp add_worktree(repo_root, branch, path) do
    case run_worktree_add(repo_root, branch, path) do
      :ok ->
        :ok

      {:error, {:git_failed, _code, output}} = original_error ->
        case recover_checkout_conflict(output, repo_root) do
          :ok -> run_worktree_add(repo_root, branch, path)
          _ -> original_error
        end
    end
  end

  defp run_worktree_add(repo_root, branch, path) do
    case System.cmd("git", ["worktree", "add", "-B", branch, path, source_ref()],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error, {:git_failed, code, String.trim(output)}}
    end
  end

  defp recover_checkout_conflict(output, repo_root) do
    with {:ok, conflicting_path} <- checkout_conflict_path(output),
         {:ok, _} <- safe_workspace_path(conflicting_path),
         :ok <- force_remove_worktree(repo_root, conflicting_path),
         :ok <- prune_worktrees(repo_root) do
      :ok
    else
      _ -> :error
    end
  end

  defp safe_workspace_path(path) do
    workspace_root =
      Application.get_env(:reverb, Reverb.Workspaces, [])
      |> Keyword.get(:root, "/tmp/reverb/workspaces")

    PathSafety.validate(path, workspace_root)
  end

  defp force_remove_worktree(repo_root, path) do
    case System.cmd("git", ["worktree", "remove", "--force", path],
           cd: repo_root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, _code} ->
        if ignorable_worktree_remove_error?(output), do: :ok, else: :error
    end
  end

  defp prune_worktrees(repo_root) do
    case System.cmd("git", ["worktree", "prune"], cd: repo_root, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error, {:git_failed, code, String.trim(output)}}
    end
  end

  defp ignorable_worktree_remove_error?(output) when is_binary(output) do
    trimmed = String.trim(output)

    String.contains?(trimmed, "is not a working tree") or
      String.contains?(trimmed, "No such file or directory")
  end

  defp run_git(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_failed, code, String.trim(output)}}
    end
  end

  defp run_git_ok(path, args) do
    case run_git(path, args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_ref do
    Application.get_env(:reverb, Reverb.Workspaces, [])
    |> Keyword.get(:source_ref, "HEAD")
  end

  defp repo_root do
    Application.get_env(:reverb, Reverb.Workspaces, [])
    |> Keyword.get(:repo_root)
  end

  defp remote_name do
    Application.get_env(:reverb, Reverb.Git, [])
    |> Keyword.get(:remote_name, "origin")
  end

  defp existing_pr_url(branch) do
    case System.cmd("gh", ["pr", "list", "--head", branch, "--json", "url", "--limit", "1"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, [%{"url" => pr_url} | _]} when is_binary(pr_url) and pr_url != "" -> {:ok, pr_url}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 32)
  end
end
