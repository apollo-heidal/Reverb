FROM hexpm/elixir:1.18.4-erlang-27.1.3-debian-bookworm-20250610-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends bash ca-certificates curl git inotify-tools postgresql-client && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN mix local.hex --force && mix local.rebar --force

ENTRYPOINT ["/workspace/docker/app-entrypoint.sh"]
