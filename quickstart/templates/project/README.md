# Reverb Quickstart

This quickstart generates your Phoenix app inside the `prod` container with `mix phx.new`, installs Reverb into it, and then layers on the `/captain` steering surface.

Open the app at `http://localhost:4000`.

Open the OpenCode auth UI at `http://localhost:4096`.

Use the OpenCode UI to connect a provider for the Reverb container.

Do not steer your app from the OpenCode UI in this quickstart. Use `http://localhost:4000/captain` for product requests.

Developer shortcut:

- If you already use OpenCode locally, you can replace the named `opencode_data` volume in `docker-compose.yml` with a host bind mount:
  - `~/.local/share/opencode:/root/.local/share/opencode`
- That preloads `auth.json` and skips provider re-auth inside the container.
