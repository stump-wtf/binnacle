# binnacle container — bootstrap story.
#
# Two stages: build the Vite + Gren SPA (web/dist), then serve it with the
# dependency-free node:http bootstrap server (server.js). The Gren server
# (gren-lang/node) replaces the CMD later; the build stage stays.
#
# amd64 only, deliberately (like stump.wtf/cairn): binnacle deploys to ie02,
# which is amd64. Revisit — with QEMU for the emulated Vite build — if
# binnacle ever lands on an arm host.
FROM node:22-alpine AS web
WORKDIR /build
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
# Warm the gren compiler cache before building: vite-plugin-gren compiles
# .gren through the gren binary it caches under $HOME, and on a cold cache it
# feeds rollup a "Compiler not found, downloading" stub that fails the build.
# Same command `make web-check` runs locally.
RUN npx gren make Main --output=/dev/null
RUN npm run build

FROM node:22-alpine
ENV NODE_ENV=production PORT=8080
WORKDIR /app
# The runtime never runs npm/corepack/yarn — server.js is dependency-free.
# Stripping the bundled package toolchain removes its dev-only CVE surface:
# Trivy flags npm's OWN dependencies (tar, brace-expansion, sigstore, ...) at
# HIGH/CRITICAL inside the stock node image, and none of it executes here.
RUN rm -rf /usr/local/lib/node_modules /opt/yarn* \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
      /usr/local/bin/yarn /usr/local/bin/yarnpkg
COPY --chown=node:node server.js ./
COPY --from=web --chown=node:node /build/dist ./dist
USER node
EXPOSE 8080
# $PORT, not a hardcoded 8080: server.js honours the env var, so an inventory
# entry that overrides PORT would otherwise be marked unhealthy forever.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" || exit 1
CMD ["node", "server.js"]
