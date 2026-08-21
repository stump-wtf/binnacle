# binnacle container — Elixir/Phoenix application (ADR-0004).
#
# Three stages: assets (Vite/Tailwind), release (mix release on Alpine so the
# runtime matches glibc-free musl), runtime (Alpine + openssl, non-root).
#
# amd64 only, deliberately (like stump.wtf/cairn): binnacle deploys to ie02,
# which is amd64. Revisit if binnacle ever lands on an arm host.
#
# The git SHA the image was built from, passed by CI as a build arg and read
# at runtime to link the running build back to the Gitea commit. A build that
# does not pass it falls through to the `unknown` default in the runtime
# stage; runtime.exs treats that as "not stamped" and the footer renders
# nothing, rather than a link to /commit/unknown.
ARG BUILD_SHA
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS assets
WORKDIR /build
COPY server/package.json server/package-lock.json ./
RUN npm ci
COPY server/vite.config.js ./
COPY server/assets ./assets
# The templates, for Tailwind to scan. Utility classes appear ONLY inside the
# .ex/.heex files under lib/ — nothing in assets/ mentions `flex` or
# `text-dim` — so a bundle built without them compiles cleanly and ships a
# stylesheet with the preflight, the theme tokens and the @font-face blocks
# but not one layout rule. That is a silent failure: `npm run build` exits 0
# and the CSS is a plausible 33KB.
COPY server/lib ./lib
RUN npm run build
# Fail the build here rather than in a browser. A stylesheet with no
# utilities renders every page as unstyled flow content, and neither the
# compile, the test suite, nor the container smoke test can see it — the
# smoke test asks for HTTP 200 and gets one.
RUN grep -q '\.flex{' priv/static/assets/app.css \
  || (echo "app.css has no Tailwind utilities — did the template sources reach this stage?" && exit 1)

FROM elixir:1.20-alpine@sha256:89d8a6f92b631d9916261371ffaf10589a57d08c5487cd042c884f1fd89ae6fb AS release
WORKDIR /build
# MIX_ENV=prod for the whole stage, hoisted above deps.compile. Setting it
# just before `mix compile` fixes the build but leaves deps.compile running
# as :dev — so it populates _build/dev, `mix compile` finds nothing reusable
# in _build/prod, and every dependency is compiled a second time. Declared
# once here so `--only $MIX_ENV` cannot drift from the release env.
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only $MIX_ENV && mix deps.compile
COPY server/config ./config
COPY server/lib ./lib
COPY server/priv ./priv
# The built bundle has to be in place BEFORE `mix release`, because that is
# what folds priv/ into the release's own app directory. Plug.Static is
# configured `from: :binnacle`, which resolves through Application.app_dir/1
# to lib/binnacle-<vsn>/priv/static inside the release — NOT to /app/priv.
# Copying the assets into /app/priv in the runtime stage therefore put them
# somewhere nothing ever reads, and the stale committed copy of
# priv/static/assets/app.css was served instead.
COPY --from=assets /build/priv/static/assets ./priv/static/assets
RUN mix compile --warnings-as-errors && mix release --overwrite

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
# Re-declare the global ARG so it is visible in this stage.
ARG BUILD_SHA=unknown
ENV PHX_SERVER=true PORT=8080
ENV BUILD_SHA=$BUILD_SHA
WORKDIR /app
# Runtime system dependencies of an Erlang/OTP release on musl: openssl for
# :crypto, libstdc++ for the NIFs, and ncurses-libs because beam.smp links
# libncursesw and exits 127 without it.
RUN apk add --no-cache openssl libstdc++ ncurses-libs && adduser -D -u 1000 binnacle
COPY --from=release --chown=binnacle:binnacle /build/_build/prod/rel/binnacle ./
USER binnacle
EXPOSE 8080
# $PORT, not a hardcoded 8080: the endpoint honours the env var (runtime.exs),
# so an inventory entry that overrides PORT would otherwise be marked
# unhealthy forever.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/" >/dev/null || exit 1
CMD ["./bin/binnacle", "start"]
