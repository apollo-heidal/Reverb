defmodule Reverb.Agent.CLI.Generic do
  @moduledoc """
  Generic non-interactive CLI runner using stdin piping via `/bin/sh`.

  This adapter is retained as a fallback, but it is not production-complete.
  """

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    command = Keyword.get(opts, :command) || Keyword.get(opts, :agent_command) || "sh"
    args = Keyword.get(opts, :args) || Keyword.get(opts, :agent_args) || []
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    env = Keyword.get(opts, :env, [])
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    prompt_file = write_prompt_file!(prompt)
    start_ms = System.monotonic_time(:millisecond)

    try do
      task =
        Task.async(fn ->
          System.cmd("/bin/sh", ["-lc", shell_command(command, args, prompt_file)],
            cd: cwd,
            stderr_to_stdout: true,
            env: env
          )
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, exit_code}} ->
          result = %{
            provider: :generic,
            command: command,
            args: args,
            output: String.trim(output),
            exit_code: exit_code,
            duration_ms: System.monotonic_time(:millisecond) - start_ms,
            timed_out: false
          }

          if exit_code == 0, do: {:ok, result}, else: {:error, {:exit_code, exit_code, result}}

        nil ->
          {:error, :timeout}
      end
    after
      File.rm(prompt_file)
    end
  end

  defp shell_command(command, args, prompt_file) do
    escaped_args = Enum.map_join(args, " ", &escape/1)
    "#{escape(command)} #{escaped_args} < #{escape(prompt_file)}"
  end

  defp write_prompt_file!(prompt) do
    path = Path.join(System.tmp_dir!(), "reverb-prompt-#{System.unique_integer([:positive])}.txt")
    File.write!(path, prompt)
    path
  end

  defp escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
