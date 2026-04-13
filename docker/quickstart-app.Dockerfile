FROM docker.io/hexpm/elixir:1.18.4-erlang-26.2.5.19-debian-bookworm-20260406-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends bash build-essential ca-certificates curl git inotify-tools postgresql-client && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace_root

RUN mix local.hex --force && mix local.rebar --force

COPY docker/quickstart-app-entrypoint.sh /usr/local/bin/reverb-quickstart-app-entrypoint
RUN chmod +x /usr/local/bin/reverb-quickstart-app-entrypoint

ENTRYPOINT ["/usr/local/bin/reverb-quickstart-app-entrypoint"]
