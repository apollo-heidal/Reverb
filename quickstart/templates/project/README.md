# Reverb Quickstart

This quickstart generates your Phoenix app inside the `prod` container with `mix phx.new`, installs Reverb into it, and then layers on the `/captain` steering surface.

The installer supports both `docker compose` and `podman compose`. Set
`REVERB_CONTAINER_ENGINE=podman` before running it if you want to force Podman.

Open the app at `http://localhost:4000`.

Open the OpenCode auth UI at `http://localhost:4096`.

If those ports are already in use, set `QUICKSTART_HOST_APP_PORT` and
`QUICKSTART_HOST_OPENCODE_PORT` before running the installer.

Use the OpenCode UI to connect a provider for the Reverb container.

The quickstart builds Phoenix assets during startup and during Reverb validation.
It does not rely on long-running Tailwind or esbuild watch processes inside the container.

Do not steer your app from the OpenCode UI in this quickstart. Use `http://localhost:4000/captain` for product requests.

Developer shortcut:

- If you already use OpenCode locally, you can replace the named `opencode_data` volume in `docker-compose.yml` with a host bind mount:
  - `~/.local/share/opencode:/root/.local/share/opencode`
- That preloads `auth.json` and skips provider re-auth inside the container.
