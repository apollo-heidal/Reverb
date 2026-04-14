defmodule Reverb.Agent.CLI do
  @moduledoc """
  Provider-neutral boundary for non-interactive coding-agent CLI execution.

  Supports a fallback chain: when `fallback: true` is passed, execution
  walks the `Reverb.Agent.Pool` chain on retryable failures, trying the
  next adapter/model pair until one succeeds or the chain is exhausted.
  """

  alias Reverb.Agent.CLI.{Claude, Codex, Generic, Hermes, OpenCode}
  require Logger

  @type result :: %{
          provider: atom(),
          command: String.t(),
          args: [String.t()],
          output: String.t(),
          exit_code: integer(),
          duration_ms: non_neg_integer(),
          timed_out: boolean()
        }

  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(prompt, opts \\ []) when is_binary(prompt) do
    if Keyword.get(opts, :fallback, false) do
      run_with_fallback(prompt, opts)
    else
      run_single(prompt, opts)
    end
  end

  defp run_with_fallback(prompt, opts) do
    case Reverb.Agent.Pool.primary() do
      nil ->
        run_single(prompt, opts)

      {adapter, model} ->
        run_chain(prompt, opts, {adapter, model}, [])
    end
  end

  defp run_chain(prompt, opts, {adapter, model}, tried) do
    Logger.info("[Reverb.CLI] Attempting #{adapter} with model #{model}")
    attempt_opts = Keyword.put(opts, :model, model)

    result =
      try do
        run_with_adapter(prompt, Keyword.put(attempt_opts, :adapter, adapter))
      rescue
        e -> {:error, {:adapter_crash, Exception.message(e)}}
      end

    case result do
      {:ok, _} = success ->
        Reverb.Agent.Pool.mark_ok(adapter)
        success

      {:error, reason} ->
        Reverb.Agent.Pool.mark_failed(adapter, reason)
        tried = [{adapter, model, reason} | tried]

        case Reverb.Agent.Pool.next_after({adapter, model}) do
          nil ->
            Logger.warning(
              "[Reverb.CLI] Fallback chain exhausted. Tried: #{format_tried(tried)}"
            )

            {:error, {:fallback_exhausted, Enum.reverse(tried)}}

          {next_adapter, next_model} ->
            Logger.info(
              "[Reverb.CLI] Falling back from #{adapter}/#{model} to #{next_adapter}/#{next_model}"
            )

            :telemetry.execute(
              [:reverb, :agent, :pool, :fallback],
              %{attempt: length(tried)},
              %{
                from_adapter: adapter,
                from_model: model,
                to_adapter: next_adapter,
                to_model: next_model,
                reason: reason
              }
            )

            run_chain(prompt, opts, {next_adapter, next_model}, tried)
        end
    end
  end

  defp run_single(prompt, opts) do
    adapter = Keyword.get(opts, :adapter, infer_adapter(opts))
    run_with_adapter(prompt, Keyword.put(opts, :adapter, adapter))
  end

  defp run_with_adapter(prompt, opts) do
    adapter = Keyword.get(opts, :adapter, :opencode)

    case adapter do
      :opencode -> OpenCode.run(prompt, opts)
      :codex -> Codex.run(prompt, opts)
      :claude -> Claude.run(prompt, opts)
      :hermes -> Hermes.run(prompt, opts)
      :generic -> Generic.run(prompt, opts)
      other -> {:error, {:unknown_adapter, other}}
    end
  end

  defp format_tried(tried) do
    tried
    |> Enum.reverse()
    |> Enum.map(fn {a, m, _reason} -> "#{a}/#{m}" end)
    |> Enum.join(" -> ")
  end

  defp infer_adapter(opts) do
    case Keyword.get(opts, :command) || Keyword.get(opts, :agent_command) do
      command when is_binary(command) ->
        executable = Path.basename(command)

        cond do
          String.contains?(executable, "opencode") -> :opencode
          String.contains?(executable, "codex") -> :codex
          String.contains?(executable, "claude") -> :claude
          String.contains?(executable, "hermes") -> :hermes
          true -> :generic
        end

      _ ->
        Keyword.get(opts, :agent_adapter, :opencode)
    end
  end
end
