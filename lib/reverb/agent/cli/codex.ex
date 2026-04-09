defmodule Reverb.Agent.CLI.Codex do
  @moduledoc """
  Codex CLI wrapper.

  This adapter is retained for compatibility, but it is not production-complete.
  """

  alias Reverb.Agent.CLI.Generic

  def run(prompt, opts \\ []) do
    command = Keyword.get(opts, :command) || Keyword.get(opts, :agent_command) || "codex"

    args =
      Keyword.get(opts, :args) || Keyword.get(opts, :agent_args) ||
        ["exec", "--dangerously-bypass-approvals-and-sandbox", "-"]

    Generic.run(
      prompt,
      opts
      |> Keyword.put(:command, command)
      |> Keyword.put(:args, args)
    )
  end
end
