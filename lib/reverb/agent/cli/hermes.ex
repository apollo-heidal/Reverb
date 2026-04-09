defmodule Reverb.Agent.CLI.Hermes do
  @moduledoc """
  Hermes CLI wrapper.

  Hermes is treated as the preferred multi-provider adapter because it can
  centralize model/provider/API-key handling outside of Reverb.

  This adapter is retained for compatibility, but it is not production-complete.
  """

  alias Reverb.Agent.CLI.Generic

  @default_args ["prompt", "--input", "-"]

  def run(prompt, opts \\ []) do
    command = Keyword.get(opts, :command) || Keyword.get(opts, :agent_command) || "hermes"
    args = build_args(opts)

    case Generic.run(
           prompt,
           opts
           |> Keyword.put(:command, command)
           |> Keyword.put(:args, args)
         ) do
      {:ok, result} ->
        {:ok, Map.put(result, :provider, :hermes)}

      {:error, {:exit_code, code, result}} ->
        {:error, {:exit_code, code, Map.put(result, :provider, :hermes)}}

      other ->
        other
    end
  end

  defp build_args(opts) do
    base_args = Keyword.get(opts, :args) || Keyword.get(opts, :agent_args) || @default_args

    []
    |> maybe_put_flag("--provider", Keyword.get(opts, :provider))
    |> maybe_put_flag("--model", Keyword.get(opts, :model))
    |> maybe_put_flag("--profile", Keyword.get(opts, :profile))
    |> Kernel.++(base_args)
  end

  defp maybe_put_flag(args, _flag, nil), do: args
  defp maybe_put_flag(args, flag, value), do: args ++ [flag, to_string(value)]
end
