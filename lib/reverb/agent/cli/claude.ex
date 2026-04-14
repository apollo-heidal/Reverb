defmodule Reverb.Agent.CLI.Claude do
  @moduledoc """
  Claude Code CLI wrapper for non-interactive autonomous runs.

  Claude is the production-default adapter. It executes
  `claude --print --output-format stream-json --verbose` and normalizes the
  NDJSON event stream into the shared CLI result shape. Output semantics mirror
  `Reverb.Agent.CLI.OpenCode` so the scheduler can treat results uniformly.
  """

  @default_args [
    "--print",
    "--output-format",
    "stream-json",
    "--verbose",
    "--dangerously-skip-permissions"
  ]

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    command = Keyword.get(opts, :command) || Keyword.get(opts, :agent_command) || "claude"
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

            cond do
              exit_code == 0 ->
                {:ok, result}

              msg = auth_error_message(output) ->
                {:error, {:auth_error, msg, Map.put(result, :auth_error, msg)}}

              true ->
                {:error, {:exit_code, exit_code, result}}
            end

          nil ->
            {:error, :timeout}
        end
    end
  end

  defp build_args(prompt, opts) do
    base_args = Keyword.get(opts, :args) || Keyword.get(opts, :agent_args) || @default_args
    model = Keyword.get(opts, :model) || Keyword.get(opts, :agent_model)

    base_args
    |> maybe_put_flag("--model", normalize_model(model))
    |> maybe_put_flag("--session-id", Keyword.get(opts, :session))
    |> maybe_put_flag("--cwd", Keyword.get(opts, :dir))
    |> Kernel.++([prompt])
  end

  defp normalize_model(nil), do: nil
  defp normalize_model(model), do: to_string(model)

  defp maybe_put_flag(args, _flag, nil), do: args

  defp maybe_put_flag(args, flag, value) do
    if Enum.any?(args, &(&1 == flag)) do
      args
    else
      args ++ [flag, to_string(value)]
    end
  end

  defp normalize_result(output, command, args, exit_code, start_ms) do
    events = parse_events(output)

    %{
      provider: :claude,
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
    cond do
      result_text = last_result_text(events) ->
        result_text

      assistant_text = join_assistant_text(events) ->
        assistant_text

      true ->
        String.trim(raw_output)
    end
  end

  defp last_result_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      case event do
        %{"type" => "result", "result" => text} when is_binary(text) and text != "" ->
          String.trim(text)

        _ ->
          nil
      end
    end)
  end

  defp join_assistant_text(events) do
    text =
      events
      |> Enum.map(&assistant_text/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.trim()

    if text == "", do: nil, else: text
  end

  defp extract_session_id(events) do
    Enum.find_value(events, fn event ->
      event["session_id"] || event["sessionId"] || get_in(event, ["session", "id"])
    end)
  end

  defp assistant_text(%{"type" => "assistant"} = event) do
    message = event["message"] || event

    case message do
      %{"content" => content} -> extract_text(content)
      _ -> nil
    end
  end

  defp assistant_text(_event), do: nil

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map(&extract_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> empty_to_nil()
  end

  defp extract_text(%{"type" => "text", "text" => text}) when is_binary(text),
    do: String.trim(text)

  defp extract_text(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp extract_text(text) when is_binary(text), do: String.trim(text)
  defp extract_text(_value), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  @auth_error_patterns [
    ~r/invalid\s+api\s+key/i,
    ~r/unauthori[sz]ed/i,
    ~r/authentication\s+failed/i,
    ~r/not\s+authenticated/i,
    ~r/please\s+run\s+\/login/i,
    ~r/run\s+`?claude\s+setup-token`?/i,
    ~r/\b401\b.*(unauth|auth)/i,
    ~r/\b403\b.*forbidden/i,
    ~r/oauth.*expired/i,
    ~r/token.*expired/i,
    ~r/credential.*invalid/i,
    ~r/login.*required/i
  ]

  defp auth_error_message(output) when is_binary(output) do
    Enum.find_value(@auth_error_patterns, fn pattern ->
      case Regex.run(pattern, output) do
        [match | _] -> surrounding_snippet(output, match)
        _ -> nil
      end
    end)
  end

  defp surrounding_snippet(output, match) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find(fn line -> line =~ match end)
    |> case do
      nil -> match
      line -> String.slice(line, 0, 240)
    end
  end
end
