defmodule Reverb.Validation do
  @moduledoc """
  Runs coordinator-managed validation commands inside an isolated workspace.
  """

  @default_allowlist_prefixes ["mix compile", "mix test"]
  @control_operator_pattern ~r/(^|\s)(\|\||&&|\||;)(\s|$)/

  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def run(cwd, opts \\ []) when is_binary(cwd) do
    config = Application.get_env(:reverb, Reverb.Validation, [])

    commands = Keyword.get(opts, :commands) || Keyword.get(config, :commands, [])

    env =
      Keyword.get(opts, :env) ||
        config
        |> Keyword.get(:env, %{})
        |> Enum.to_list()

    allowlist_prefixes = Keyword.get(config, :allowlist_prefixes, @default_allowlist_prefixes)
    allow_control_operators = Keyword.get(config, :allow_control_operators, false)

    with {:ok, validated_commands} <-
           validate_commands(commands, allowlist_prefixes, allow_control_operators),
         {:ok, bootstrap_outputs} <- bootstrap_workspace(cwd, env) do
      Enum.reduce_while(validated_commands, {:ok, bootstrap_outputs}, fn command, {:ok, outputs} ->
        case System.cmd("/bin/sh", ["-lc", command], cd: cwd, stderr_to_stdout: true, env: env) do
          {output, 0} ->
            {:cont, {:ok, [format_output(command, output) | outputs]}}

          {output, code} ->
            {:halt,
             {:error,
              %{
                command: command,
                exit_code: code,
                output: String.trim(output),
                combined_output:
                  Enum.reverse([format_output(command, output) | outputs]) |> Enum.join("\n\n")
              }}}
        end
      end)
      |> case do
        {:ok, outputs} ->
          :telemetry.execute(
            [:reverb, :validation, :finished],
            %{count: 1},
            %{status: :passed, command_count: length(validated_commands)}
          )

          {:ok, Enum.reverse(outputs) |> Enum.join("\n\n")}

        {:error, %{command: command} = error} ->
          :telemetry.execute(
            [:reverb, :validation, :finished],
            %{count: 1},
            %{status: :failed, command: command}
          )

          {:error, error}

        {:error, _} = error ->
          error
      end
    end
  end

  defp validate_commands(commands, allowlist_prefixes, allow_control_operators)
       when is_list(commands) do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, acc} ->
      case validate_command(command, allowlist_prefixes, allow_control_operators) do
        :ok -> {:cont, {:ok, [String.trim(command) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, _} = error -> error
    end
  end

  defp validate_commands(_commands, _allowlist_prefixes, _allow_control_operators) do
    {:error, %{error: :invalid_validation_commands, reason: "commands must be a list of strings"}}
  end

  defp validate_command(command, allowlist_prefixes, allow_control_operators)
       when is_binary(command) do
    trimmed = String.trim(command)

    cond do
      trimmed == "" ->
        {:error, %{error: :invalid_validation_command, command: command, reason: "blank command"}}

      Regex.match?(@control_operator_pattern, trimmed) and not allow_control_operators ->
        {:error,
         %{
           error: :validation_command_rejected,
           command: trimmed,
           reason: "control operators are not allowed"
         }}

      not Enum.any?(allowlist_prefixes, &String.starts_with?(trimmed, &1)) ->
        {:error,
         %{
           error: :validation_command_rejected,
           command: trimmed,
           reason: "command is not on the allowlist"
         }}

      true ->
        :ok
    end
  end

  defp validate_command(command, _allowlist_prefixes, _allow_control_operators) do
    {:error,
     %{error: :invalid_validation_command, command: inspect(command), reason: "command must be a string"}}
  end

  defp format_output(command, output) do
    "$ #{command}\n" <> String.trim(output)
  end

  defp bootstrap_workspace(cwd, env) do
    mix_file = Path.join(cwd, "mix.exs")

    if File.exists?(mix_file) do
      case System.cmd("mix", ["deps.get"], cd: cwd, stderr_to_stdout: true, env: env) do
        {output, 0} -> {:ok, [format_output("mix deps.get", output)]}

        {output, code} ->
          {:error,
           %{
             command: "mix deps.get",
             exit_code: code,
             output: String.trim(output),
             combined_output: format_output("mix deps.get", output)
           }}
      end
    else
      {:ok, []}
    end
  end
end
