.PHONY: build test lint check ci

# Uniform entry points (CI invokes the same targets).
# The Gren monorepo skeleton (server/ web/ packages/core) lands with the
# bootstrap story; until then test is an honest no-op and build is a stub.

build:
	@echo "binnacle: nothing to build yet — Gren monorepo skeleton lands with the bootstrap story"

test:
	@echo "binnacle: no test suite yet — gren-lang/test lands with the bootstrap story"

# Secret scan. gitleaks: brew install gitleaks (or use the pinned CI workflow).
lint:
	gitleaks git . --redact

check: lint test

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
