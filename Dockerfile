# binnacle container — Elixir/Phoenix application (ADR-0004).
#
# Three stages: assets (Vite/Tailwind), release (mix release on Alpine so the
# runtime matches glibc-free musl), runtime (Alpine + openssl, non-root).
#
# amd64 only, deliberately (like stump.wtf/cairn): binnacle deploys to ie02,
# which is amd64. Revisit if binnacle ever lands on an arm host.
FROM node:22-alpine AS assets
WORKDIR /build
COPY server/package.json server/package-lock.json ./
RUN npm ci
COPY server/vite.config.js ./
COPY server/assets ./assets
RUN npm run build

FROM elixir:1.18-alpine AS release
WORKDIR /build
RUN mix local.hex --force && mix local.rebar --force
COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY server/config ./config
COPY server/lib ./lib
COPY server/priv ./priv
ENV MIX_ENV=prod
RUN mix compile --warnings-as-errors && mix release --overwrite

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
ENV PHX_SERVER=true PORT=8080
WORKDIR /app
# The release needs openssl at runtime for crypto; that is the only system
# dependency a Phoenix release has.
RUN apk add --no-cache openssl libstdc++ && adduser -D -u 1000 binnacle
COPY --from=release --chown=binnacle:binnacle /build/_build/prod/rel/binnacle ./
COPY --from=assets --chown=binnacle:binnacle /build/priv/static/assets ./priv/static/assets
USER binnacle
EXPOSE 8080
# $PORT, not a hardcoded 8080: the endpoint honours the env var (runtime.exs),
# so an inventory entry that overrides PORT would otherwise be marked
# unhealthy forever.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/" >/dev/null || exit 1
CMD ["./bin/binnacle", "start"]
