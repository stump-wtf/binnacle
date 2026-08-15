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

Pre-implementation. The architecture record and first specification have landed:

- [ADR-0001 — Gren full-stack base stack](docs/adrs/ADR-0001-gren-fullstack-base-stack.md)
- [ADR-0002 — StumpCloud fleet taxonomy](docs/adrs/ADR-0002-stumpcloud-fleet-taxonomy.md)
- [SPEC-0001 — Fleet taxonomy: model, config, discovery](docs/specs/fleet-taxonomy/spec.md) (+ [design](docs/specs/fleet-taxonomy/design.md))

Sprint stories live in this repo's issue tracker.

## Stack

One language end-to-end: [Gren](https://gren-lang.org/) — a browser SPA built
through Vite, a Node server (`gren-lang/node`: HTTP, SQLite, filesystem,
child processes), and a shared `packages/core` holding the wire contract and
domain types. See ADR-0001 for the full rationale.

## Development

```sh
make check   # lint + test
make lint    # gitleaks secret scan
make test    # test suite (lands with the monorepo bootstrap story)
```

The baseline config (`binnacle.json`) declares sites, hosts, and integration
credentials; it is gitignored because it carries live API keys — copy from the
committed example once it exists.

## Canonical repo

This Gitea repo (`stump.wtf/binnacle`) is the source of truth. The GitHub copy
under `stump-wtf/binnacle` is a read-only push mirror — do not open PRs or
issues there.
