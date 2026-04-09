defmodule ReverbDemoApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :reverb_demo_app,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ReverbDemoApp.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:reverb, path: System.get_env("REVERB_PATH") || "../.."}
    ]
  end
end
