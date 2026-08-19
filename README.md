# binnacle — StumpCloud fleet monitor

binnacle monitors and controls the StumpCloud fleet: **sites → hosts → VMs →
containers**, with hardware metrics (usage, consumption, capacity, temperature)
visible at both the host and the VM level — including hardware passed through to
VMs.

Each site is a home or an Airbnb with a UniFi gateway and one Home Assistant;
one or more Proxmox hardware hosts per site run Ubuntu VMs whose services ship
as Docker containers fronted by Caddy.

## Documentation

The ADRs and specs below are published as a browsable site, styled with the
Bubbletea TUI design system:

**https://stump-wtf.pages.stump.rocks/binnacle/**

It is built from `docs/` on every PR and published on merge to `main` (see the
`docs` job in `.gitea/workflows/pipeline.yaml`). Build it locally with
`make docs-install && make docs-serve`. The Pages host resolves on the LAN only.

## Status

Bootstrap landed. The Elixir/Phoenix base and the hardware-metrics zen overview
are live; discovery integrations (UniFi, Proxmox, Docker, Home Assistant) are
the next story:

- [ADR-0001 — Gren full-stack base stack](docs/adrs/ADR-0001-gren-fullstack-base-stack.md) — *superseded by ADR-0004*
- [ADR-0002 — StumpCloud fleet taxonomy](docs/adrs/ADR-0002-stumpcloud-fleet-taxonomy.md)
- [ADR-0003 — Service discovery](docs/adrs/ADR-0003-stumpcloud-service-discovery.md)
- [ADR-0004 — Elixir full-stack base stack](docs/adrs/ADR-0004-elixir-fullstack-base-stack.md)
- [ADR-0005 — Hardware metrics over time: the zen overview](docs/adrs/ADR-0005-hardware-metrics-zen-overview.md)
- [SPEC-0001 — Fleet taxonomy: model, config, discovery](docs/specs/fleet-taxonomy/spec.md) (+ [design](docs/specs/fleet-taxonomy/design.md))
- [SPEC-0002 — Service discovery: manifest enrichment](docs/specs/service-discovery/spec.md)

Sprint stories live in this repo's issue tracker.

## Stack

One language end-to-end: [Elixir](https://elixir-lang.org/) — a Phoenix 1.8
application in [`server/`](server/) with Phoenix LiveView screens over a fleet
domain context (`Binnacle.Fleet`: the taxonomy, the baseline config, the
metrics history, and the sample clock). Readings currently come from
`Binnacle.Fleet.Sampler` (ADR-0005); the discovery story replaces it in place.

The design stack is unchanged from the original web work: Tailwind CSS v4 +
daisyUI driven by the Bubbletea TUI design system, now compiled by Vite into
`server/priv/static/assets` and consumed by HEEx function components in
`server/lib/binnacle_web/components/ui/`. See [`docs/design/`](docs/design/)
for the design language.

## Development

The Elixir toolchain is provided by the host's `mix` if present, or
automatically by the pinned `elixir:1.18-alpine` docker image otherwise.

```sh
make check          # format check + gitleaks + compile --warnings-as-errors + tests
make server-build   # Vite asset bundle
make server-dev     # run the Phoenix server on :4000
make config-check   # validate the baseline fleet config
```

`/` is the fleet overview; `/gallery` is the design-stack gallery that
exercises every `Ui.*` component.

The baseline config (`binnacle.json`) declares sites, hosts, and integration
credentials; it is gitignored because it carries live API keys — copy from the
committed example once it exists.

## Canonical repo

This Gitea repo (`stump.wtf/binnacle`) is the source of truth. The GitHub copy
under `stump-wtf/binnacle` is a read-only push mirror — do not open PRs or
issues there.
