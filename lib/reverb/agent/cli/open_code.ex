defmodule Reverb.Agent.CLI.OpenCode do
  @moduledoc """
  OpenCode CLI wrapper for non-interactive autonomous runs.

  OpenCode is the production-default adapter. It executes `opencode run` in JSON
  mode and normalizes event output into the shared CLI result shape.
  """

  @default_args ["run", "--format", "json", "--dangerously-skip-permissions"]
  @assistant_event_types MapSet.new([
                           "assistant",
                           "assistant_message",
                           "final",
                           "final_message",
                           "message",
                           "message.completed",
                           "response.completed"
                         ])

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    command = Keyword.get(opts, :command) || Keyword.get(opts, :agent_command) || "opencode"
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    env = Keyword.get(opts, :env, [])
    timeout_ms = Keyword.get(opts, :timeout_ms, 600_000)
    start_ms = System.monotonic_time(:millisecond)
    args = build_args(prompt, opts)

    case System.find_executable(command) do
      nil ->
        {:error, {:command_not_found, command}}

      _ ->
        task =
          Task.async(fn ->
            System.cmd(command, args,
              cd: cwd,
              env: env,
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, exit_code}} ->
            result =
              output
              |> normalize_result(command, args, exit_code, start_ms)
              |> Map.put(:timed_out, false)

            if exit_code == 0, do: {:ok, result}, else: {:error, {:exit_code, exit_code, result}}

          nil ->
            {:error, :timeout}
        end
    end
  end

  defp build_args(prompt, opts) do
    base_args = Keyword.get(opts, :args) || Keyword.get(opts, :agent_args) || @default_args

    base_args
    |> maybe_put_flag("--model", Keyword.get(opts, :model) || Keyword.get(opts, :agent_model))
    |> maybe_put_flag("--session", Keyword.get(opts, :session))
    |> maybe_put_flag("--agent", Keyword.get(opts, :agent))
    |> maybe_put_flag("--variant", Keyword.get(opts, :variant))
    |> maybe_put_flag("--dir", Keyword.get(opts, :dir))
    |> Kernel.++([prompt])
  end

  defp maybe_put_flag(args, _flag, nil), do: args

  defp maybe_put_flag(args, flag, value) do
    if Enum.any?(args, &(&1 == flag or &1 == short_flag(flag))) do
      args
    else
      args ++ [flag, to_string(value)]
    end
  end

  defp short_flag("--model"), do: "-m"
  defp short_flag("--session"), do: "-s"
  defp short_flag(_flag), do: nil

  defp normalize_result(output, command, args, exit_code, start_ms) do
    events = parse_events(output)

    %{
      provider: :opencode,
      command: command,
      args: args,
      output: final_output(output, events),
      raw_output: String.trim(output),
      exit_code: exit_code,
      duration_ms: System.monotonic_time(:millisecond) - start_ms,
      timed_out: false,
      session_id: extract_session_id(events),
      events: events
    }
  end

  defp parse_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{} = event} -> [event | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp final_output(raw_output, events) do
    assistant_text =
      events
      |> Enum.map(&assistant_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.trim()

    if assistant_text == "", do: String.trim(raw_output), else: assistant_text
  end

  defp extract_session_id(events) do
    Enum.find_value(events, fn event ->
      event["sessionID"] || event["sessionId"] || get_in(event, ["session", "id"])
    end)
  end

  defp assistant_text(%{"type" => type} = event) do
    if MapSet.member?(@assistant_event_types, type) do
      role = event["role"] || get_in(event, ["message", "role"]) || "assistant"

      if role == "assistant" do
        extract_text(event)
      end
    end
  end

  defp assistant_text(_event), do: nil

  defp extract_text(%{"text" => text}) when is_binary(text), do: String.trim(text)

  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&extract_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.trim()
    |> empty_to_nil()
  end

  defp extract_text(%{"content" => content}) when is_binary(content), do: String.trim(content)
  defp extract_text(%{"message" => message}) when is_map(message), do: extract_text(message)

  defp extract_text(%{"delta" => delta}) when is_binary(delta), do: String.trim(delta)
  defp extract_text(%{"parts" => parts}) when is_list(parts), do: extract_text(%{"content" => parts})

  defp extract_text(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.find_value(&extract_text/1)
  end

  defp extract_text(text) when is_binary(text), do: String.trim(text)
  defp extract_text(_value), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
