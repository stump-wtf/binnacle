.PHONY: build test lint check ci config-check

# Uniform entry points (CI invokes the same targets).
#
# The whole application is the Elixir/Phoenix project in server/ (ADR-0004).
# The Elixir toolchain is provided either by the host (if `mix` is on PATH)
# or by the pinned elixir docker image, so the targets work on any checkout.

MIX := $(shell command -v mix >/dev/null 2>&1 && echo mix || echo docker-run-mix)
ELIXIR_IMAGE := elixir:1.18-alpine

build: server-build

# ---- elixir toolchain wrapper ----------------------------------------------

define mix-in-docker
cd server && docker run --rm -v "$$(pwd)":/app -w /app $(ELIXIR_IMAGE) \
	sh -c "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix $(1)"
endef

server-deps:
	@if [ "$(MIX)" = mix ]; then cd server && mix deps.get; else $(call mix-in-docker,deps.get); fi

server-test:
	@if [ "$(MIX)" = mix ]; then cd server && mix test; else $(call mix-in-docker,test); fi

server-compile:
	@if [ "$(MIX)" = mix ]; then cd server && mix compile --warnings-as-errors; else $(call mix-in-docker,compile --warnings-as-errors); fi

server-format-check: server-deps
	@if [ "$(MIX)" = mix ]; then cd server && mix format --check-formatted; else $(call mix-in-docker,format --check-formatted); fi

.PHONY: server-deps server-test server-compile server-format-check

# ---- assets ----------------------------------------------------------------
#
# Vite + Tailwind v4 + daisyUI, straight into server/priv/static/assets.
# Node is only the asset toolchain — the runtime never runs npm (ADR-0004).

server-install:
	cd server && npm install

server-build: server-install
	cd server && npm run build

.PHONY: server-install server-build

# ---- tests / lint / check ----------------------------------------------------

test: server-deps server-test

# Secret scan (gitleaks: brew install gitleaks) plus formatter drift.
lint: server-format-check
	gitleaks git . --redact

check: lint server-deps server-compile test

ci: check server-build

# Validate the baseline fleet config: fails fast, naming the offender.
config-check:
	@if [ "$(MIX)" = mix ]; then cd server && mix run -e "Binnacle.Fleet.Config.load!(\"priv/fleet/baseline.json\") && IO.puts(\"baseline ok\")"; \
	 else cd server && docker run --rm -v "$$(pwd)":/app -w /app $(ELIXIR_IMAGE) \
		sh -c "mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix run -e 'Binnacle.Fleet.Config.load!(\"priv/fleet/baseline.json\") && IO.puts(\"baseline ok\")'"; fi

.PHONY: config-check

# ---- dev --------------------------------------------------------------------

server-dev: server-build
	@if [ "$(MIX)" = mix ]; then cd server && mix phx.server; else $(call mix-in-docker,phx.server); fi

.PHONY: server-dev

# ---- docs site -----------------------------------------------------------
# Docusaurus site published to https://stump-wtf.pages.stump.rocks/binnacle/
# by the `docs` job in .gitea/workflows/pipeline.yaml. CI runs `npm ci &&
# npm run build` in docs-site/ via the shared stump.wtf/ci static-site
# workflow — the same two commands these targets wrap, so local and CI cannot
# drift. Not wired into `check` (see the workflow comment).

docs-install:
	cd docs-site && npm ci

docs:
	cd docs-site && npm run build

docs-serve:
	cd docs-site && npm run start

.PHONY: docs docs-install docs-serve
