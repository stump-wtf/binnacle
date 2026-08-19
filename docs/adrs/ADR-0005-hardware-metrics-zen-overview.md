---
status: accepted
date: 2026-08-18
decision-makers: [joestump]
extends: [ADR-0002, ADR-0004]
---

# ADR-0005: Hardware metrics over time — the zen overview

## Context and Problem Statement

The fleet taxonomy (ADR-0002) gives binnacle the containment spine: Site → Host → Guest → Container, with hardware attached at either host or guest level. A fleet monitor's primary screen has to answer two questions at a glance: *what is it doing right now*, and *where is it heading* — a host at 70% CPU that has been climbing for ten minutes is a different animal from one loafing at 70%. What does binnacle's overview look like, and where do its readings come from before live discovery exists?

## Decision Drivers

* The overview must show every site, host, VM, and container on one page, in a state calm enough to leave on a wall display: "zen" — low contrast, no motion except the data itself, colour reserved for status.
* Every hardware reading needs a trend: a metric without history is a snapshot, and snapshots hide ramps.
* Status colour must stay honest: the same four states, the same hues, `unknown` grey rather than red (a monitoring gap is not an outage).
* The overview must exist and be exercised before the Proxmox/UniFi/Docker discovery integrations land, so the UI is proven against realistic data rather than built against a stub that never grows up.

## Considered Options

* **Zen overview with sampled metrics** (chosen) — full spine + a sampler producing plausible drifting readings
* Wait for live discovery, ship the overview then (blocks all UI work on integrations)
* Charts library (Chart.js/uPlot) for trends (a JS chart runtime for what are, here, single-series lines)

## Decision Outcome

Chosen option: "zen overview with sampled metrics". `Binnacle.Fleet.Sampler` produces per-host readings on slow sinusoids with per-node phase plus deterministic noise, smoothed toward the previous sample — enough realism that meters cross thresholds, statuses roll up degraded, and trend lines show load coming and going. Its shape is deliberately a real poller's shape (`(node, tick) -> Sample`), so the discovery story replaces it in place.

The screen: one row per host — name, rolled-up status chip, cpu/mem/temp readings each with a `Ui.Sparkline` beside it — expanding in place into the hardware panel (meters for cpu/memory/disk/package temp/hdd temp, full-width trend lines, device inventory with SMART chips, and the guest/container tree with passthrough devices marked).

### Consequences

* Good, because the whole UI story — meters, sparklines, expansion, live ticks over PubSub — is real and tested today; discovery lands into a finished surface.
* Good, because sparklines are pure SVG geometry computed in Elixir: server-rendered on first paint, no chart runtime, no client JavaScript beyond the LiveView socket and theme hook.
* Good, because nil readings gap the trend line rather than interpolating — missing data must look missing.
* Bad, because the readings are simulated; every screen that matters says so until discovery replaces the sampler (the sampler's moduledoc and this ADR are the contract).
* Bad, because history is in-memory only (capped 120 samples ≈ 10 minutes at 5s cadence); persistence arrives with the storage story, and until then a restart forgets the trends.

## Notes

* `Ui.Sparkline` is the trend companion to `Ui.Meter`: the meter says what it is, the sparkline says where it is going. The line is dim texture while nominal and takes the status hue only outside nominal — a wall of sparklines must not read as N competing charts.
* Status roll-up follows ADR-0002: a parent is as bad as its worst child, except `unknown` children never manufacture an outage.
