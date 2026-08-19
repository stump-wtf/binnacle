---
status: accepted
date: 2026-08-18
decision-makers: [joestump]
supersedes: [ADR-0001]
---

# ADR-0004: Elixir full-stack base for binnacle

## Context and Problem Statement

ADR-0001 chose Gren (https://gren-lang.org/) as binnacle's end-to-end language: one statically-typed functional language compiled to both the browser SPA and the Node server, with the wire contract defined once in a shared `packages/core` package. The design-stack gallery shipped on it, but the base stack is being replaced wholesale: binnacle's base is now **Elixir (https://elixir-lang.org/)** — still all functional programming, but on the BEAM, with **Phoenix + Phoenix LiveView** as the application framework. This ADR records the new base-stack decision and supersedes ADR-0001.

## Decision Drivers

* One functional language end-to-end, with the domain model defined once and shared by every view of it.
* A runtime and ecosystem that can carry a long-lived fleet monitor: supervision trees, a real OTP distribution story, mature HTTP/WebSocket/metrics libraries.
* Server-driven UI with minimal client JavaScript: LiveView gives interactive, stateful screens (selection, expansion, live updates) with the UI defined in the same language and process space as the domain.
* The Bubbletea web design system (Tailwind v4 + daisyUI + design tokens) carries over unchanged — it is a CSS contract, not a Gren artifact.
* Uniform `make test` / `make lint` / `make check` entry points wired into CI (per the org-wide Makefile rule).

## Considered Options

* **Elixir + Phoenix + LiveView** (chosen) — functional, BEAM, one language for domain and UI
* Gren full-stack (superseded ADR-0001 plan; pre-1.0 compiler, ~45-package ecosystem)
* Go backend + templ/htmx (fleet symmetry, but a second language for the interactive UI)
* TypeScript full-stack (Node everywhere, but not functional-first)

## Decision Outcome

Chosen option: "Elixir + Phoenix + LiveView", because it keeps the whole application in one functional language while putting it on the BEAM — a runtime built for exactly this shape of long-running, stateful, supervision-friendly service — and LiveView removes the SPA/second-compile-target problem ADR-0001 was solving with Gren in the first place.

### Consequences

* Good, because the UI is server-rendered HEEx function components in the same modules as the domain: no wire contract to keep in sync at all in the common case, and interactive state (theme, selection, expansion) is LiveView state.
* Good, because OTP gives the fleet context a natural home: one supervised GenServer (`Binnacle.Fleet`) owns the baseline config, the metrics history, and the sample clock, and LiveViews subscribe to its PubSub ticks.
* Good, because the ecosystem is deep: Bandit/Plug, Jason, ExUnit with LiveViewTest, `mix format` as the formatter, Credo available when lint appetite grows.
* Good, because the asset pipeline stays the known-good Vite + Tailwind v4 + daisyUI stack from ADR-0001's web work — only the Gren compiler plugin is gone.
* Bad, because the client still needs a little JavaScript (the LiveView socket plus one theme hook) — it is glue in `assets/js/app.js`, and anything beyond glue is a defect.
* Bad, because the container is now a BEAM runtime rather than either a static binary or plain Node — larger than either, mitigated by `mix release` on Alpine.
* Bad, because binnacle remains the non-Go service in a Go fleet; the maintainability pool is still us and the agents.

## How We Structure the Project

```
binnacle/
  server/                      # the whole application: Phoenix umbrella-free Mix project
    lib/binnacle/              # the domain: fleet model, config, sampler, context GenServer
    lib/binnacle_web/          # LiveViews + Ui.* function components + layouts
    assets/js, assets/styles   # Vite entry + the Bubbletea design stack CSS
    priv/fleet/baseline.json   # the baseline fleet config (SPEC-0001)
    test/                      # ExUnit: domain, components, LiveView tests
  docs/adrs/, docs/specs/
  Dockerfile                   # assets (node) → mix release (elixir) → alpine runtime
  Makefile                     # make test / lint / check wrap mix + gitleaks + vite build
```

* **`lib/binnacle`** is the single source of truth for the taxonomy (ADR-0002) and its metrics. LiveViews read it through `Binnacle.Fleet.snapshot/0`; nothing renders from raw GenServer state.
* **`lib/binnacle_web/components/ui`** is the ported `Ui.*` library — the same components, class strings, and design-system reasoning as the Gren gallery, now as HEEx function components with `attr` declarations the compiler checks at every call site.
* The **theme mechanism** is unchanged: `data-theme` on `<html>`, resolved by an inline pre-paint bootstrap script in the root layout, persisted under `binnacle-theme`, and kept in step by a `ThemeSync` LiveView hook.

## Toolchain Notes

* Elixir 1.18, Phoenix 1.8, LiveView 1.2, Bandit as the adapter.
* Assets: Vite 7 + Tailwind v4 + daisyUI 5, output to `priv/static/assets` with unhashed names (the container image is immutable; see `server/vite.config.js`).
* `mix format` is the formatter; `mix compile --warnings-as-errors` plus `mix test` are the gates; gitleaks remains the secret scan.
