FROM hexpm/elixir:1.18.4-erlang-27.1.3-debian-bookworm-20250610-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends bash ca-certificates curl git openssh-client postgresql-client && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/reverb

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get

COPY lib lib
COPY priv priv
COPY docker docker
COPY README.md README.md

RUN chmod +x docker/reverb-entrypoint.sh

ENV MIX_ENV=prod

RUN mix compile

RUN set -eux; \
    curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path; \
    install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode; \
    opencode --version; \
    rm -rf /root/.opencode

ENTRYPOINT ["/opt/reverb/docker/reverb-entrypoint.sh"]
