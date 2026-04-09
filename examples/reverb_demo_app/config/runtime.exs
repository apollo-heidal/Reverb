import Config

if mode = System.get_env("REVERB_MODE") do
  config :reverb, mode: String.to_atom(mode)
end

if source = System.get_env("REVERB_DEMO_SOURCE") do
  config :reverb_demo_app, :source_name, source
end
