.PHONY: build test lint check ci

# Uniform entry points (CI invokes the same targets).
# server/ and packages/core land with the bootstrap story; web/ exists now as
# the design stack (CSS + Ui.* component library), so build and check reach
# into it and test stays an honest no-op until gren-lang/test arrives.

build: web-build

test:
	@echo "binnacle: no test suite yet — gren-lang/test lands with the bootstrap story"

# Secret scan. gitleaks: brew install gitleaks (or use the pinned CI workflow).
lint:
	gitleaks git . --redact

# ---- web (browser SPA + design stack) ------------------------------------
# `web-check` is the Gren type-checker and is the cheap gate: it needs only the
# gren binary from node_modules plus the committed gren_packages/, so it runs
# offline and in about a second. That is why `check` depends on it — a broken
# component signature should fail as fast as a gitleaks finding.
#
# `web-build` is the full Vite + Tailwind + daisyUI bundle. Separate, because
# it is the only part that needs the npm dependency tree resolved.
#
# web-install pins to `npm ci` so CI and local installs resolve identically.
# Note vite is held at 7.x deliberately: vite-plugin-gren@0.6.1 peers on 7.x and
# vite 8 produces an ERESOLVE conflict.

web-install:
	cd web && npm ci

web-check:
	cd web && npx gren make Main --output=/dev/null

web-build:
	cd web && npm run build

web-dev:
	cd web && npm run dev

.PHONY: web-install web-check web-build web-dev

check: lint web-check test

ci: check

# ---- docs site -----------------------------------------------------------
# Docusaurus site published to https://stump-wtf.pages.stump.rocks/binnacle/
# by the `docs` job in .gitea/workflows/pipeline.yaml. CI runs `npm ci &&
# npm run build` in docs-site/ via the shared stump.wtf/ci static-site
# workflow — the same two commands these targets wrap, so local and CI cannot
# drift.
#
# Not wired into `check`: the site is built by its own CI job on every PR
# already, and making `make check` depend on a 1400-package npm install would
# put a node toolchain in the way of a one-line gitleaks run.

docs-install:
	cd docs-site && npm ci

docs:
	cd docs-site && npm run build

docs-serve:
	cd docs-site && npm run start

.PHONY: docs docs-install docs-serve
