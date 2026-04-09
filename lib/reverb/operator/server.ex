defmodule Reverb.Operator.Server do
  @moduledoc false

  def child_spec(opts \\ []) do
    config = Application.get_env(:reverb, Reverb.Operator, []) |> Keyword.merge(opts)

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Reverb.Operator.Router,
      options: [ip: Keyword.get(config, :ip, {127, 0, 0, 1}), port: Keyword.get(config, :port, 4010)]
    )
  end
end
