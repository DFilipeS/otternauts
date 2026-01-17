# syntax=docker/dockerfile:1

ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28.3
ARG DEBIAN_VERSION=trixie-20260112-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# =============================================================================
# Builder stage
# =============================================================================
FROM ${BUILDER_IMAGE} AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY lib lib

RUN mix compile

RUN mix release otturnaut

# =============================================================================
# Runtime stage
# =============================================================================
FROM ${RUNNER_IMAGE} AS runner

ENV LANG=C.UTF-8
ENV MIX_ENV=prod

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      openssl \
      libncurses6 \
      locales \
      ca-certificates \
      git \
      openssh-client \
      tar \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash otturnaut

WORKDIR /app

COPY --from=builder --chown=otturnaut:otturnaut /app/_build/prod/rel/otturnaut ./

USER otturnaut

LABEL org.opencontainers.image.title="Otturnaut"
LABEL org.opencontainers.image.description="Otternauts agent for managing web application deployments"
LABEL org.opencontainers.image.source="https://github.com/DFilipeS/otternauts"
LABEL org.opencontainers.image.licenses="MIT"

CMD ["bin/otturnaut", "start"]
