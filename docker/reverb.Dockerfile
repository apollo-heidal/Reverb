FROM docker.io/hexpm/elixir:1.18.4-erlang-26.2.5.19-debian-bookworm-20260406-slim

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

# Claude's --dangerously-skip-permissions flag refuses to run as root unless
# IS_SANDBOX=1. This image runs as root by design, so we opt in here.
ENV IS_SANDBOX=1

RUN mix compile

RUN set -eux; \
    curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path; \
    install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode; \
    opencode --version; \
    rm -rf /root/.opencode

# Claude Code CLI is the default agent adapter. Install alongside opencode so
# both are available; the active adapter is selected at runtime via
# REVERB_AGENT_ADAPTER. Prefer the native installer; fall back to npm if the
# native installer is unavailable in this environment.
RUN set -eux; \
    if curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh; then \
        bash /tmp/claude-install.sh || true; \
        rm -f /tmp/claude-install.sh; \
    fi; \
    if ! command -v claude >/dev/null 2>&1; then \
        for bin in /root/.claude/bin/claude /root/.local/bin/claude /usr/local/bin/claude; do \
            if [ -x "$bin" ]; then ln -sf "$bin" /usr/local/bin/claude; break; fi; \
        done; \
    fi; \
    if ! command -v claude >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends ca-certificates gnupg; \
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
        apt-get install -y --no-install-recommends nodejs; \
        npm install -g @anthropic-ai/claude-code; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    claude --version

ENTRYPOINT ["/opt/reverb/docker/reverb-entrypoint.sh"]
