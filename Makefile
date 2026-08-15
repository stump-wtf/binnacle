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
