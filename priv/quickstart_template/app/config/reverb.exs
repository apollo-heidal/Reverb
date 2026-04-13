import Config

config :reverb,
  mode: :emitter,
  topic_hash: "captain-reverb_quickstart_template-1776056332",
  pubsub_name: ReverbQuickstartTemplate.PubSub

config :reverb, Reverb.Emitter,
  logger_handler: true,
  telemetry_events: []

config :reverb, Reverb.Validation,
  commands: [
    "mix compile",
    "mix test"
  ]

config :reverb, Reverb.ProdControl,
  module: ReverbQuickstartTemplate.Reverb.Control

config :reverb, Reverb.Captain,
  enabled: true

config :reverb, Reverb.Git,
  remote_enabled: false,
  push_enabled: false,
  auto_promote: false,
  protected_branches: ["main", "master", "prod", "production"]
