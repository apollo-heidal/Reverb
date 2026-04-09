defmodule Reverb.Agent.CLI do
  @moduledoc """
  Provider-neutral boundary for non-interactive coding-agent CLI execution.
  """

  alias Reverb.Agent.CLI.{Claude, Codex, Generic, Hermes, OpenCode}

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
    adapter = Keyword.get(opts, :adapter, infer_adapter(opts))

    case adapter do
      :opencode -> OpenCode.run(prompt, opts)
      :codex -> Codex.run(prompt, opts)
      :claude -> Claude.run(prompt, opts)
      :hermes -> Hermes.run(prompt, opts)
      :generic -> Generic.run(prompt, opts)
      other -> {:error, {:unknown_adapter, other}}
    end
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
