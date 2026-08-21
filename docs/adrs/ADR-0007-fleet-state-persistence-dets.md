---
status: accepted
date: 2026-08-21
decision-makers: [joestump]
extends: [ADR-0004, ADR-0005]
---

# ADR-0007: Fleet state persistence — DETS for crash survival, no owned time-series store

## Context and Problem Statement

Binnacle has no database. No Ecto, no SQLite, nothing in `server/mix.exs`. All fleet state — topology, per-host sample history, poll miss counters, UniFi network state — lives in one in-memory GenServer (`Binnacle.Fleet`). ADR-0005's premise is that "a metric without history is a snapshot, and snapshots hide ramps," but the 120-sample history (~10 minutes at 5s cadence) resets to empty on every container restart, hiding exactly the ramps it was built to show. SPEC-0001 carries a "Database Operation Standards" requirement that currently applies to nothing.

The question is not "add a database" but *which shape*, and whether the answer is a database at all. This ADR records the decision and its tradeoffs so #55 (config drift), future retention, and future alerting all know what to build on.

## Decision Drivers

* Binnacle is a wall-display fleet monitor, not a long-term metrics archive. Its job is the live overview; the fleet already runs Prometheus exporters and Beszel for retention.
* The worst symptom is a restart wiping the 10-minute trend window, making every post-deploy page look like a cold start. The cheapest fix that removes this symptom is the right one.
* Adding Ecto + SQLite or Postgres introduces a dependency, a migration story, and a pool to supervise — to a service that currently has none of those. The cost is real and ongoing.
* The BEAM ships DETS — a disk-based ETS — in the standard library. It needs no external dependency, no supervision tree change beyond a single `:dets` open on boot, and no migration files.
* A time-series store (Prometheus, VictoriaMetrics, Beszel) is the right tool for "was ogma this hot last week" — but binnacle should *read* from one rather than own one, because the fleet already has one and duplicating it adds operational burden without value.

## Considered Options

* **DETS for crash survival** (chosen) — persist the last N samples per host to a DETS table so a restart restores the trend window. No long-term retention; "was ogma this hot last week" is a question for Prometheus/Beszel, not binnacle.
* **Nothing — accept in-memory only** — legitimate if binnacle is only ever a live wall display, but then SPEC-0001's "Database Operation Standards" requirement should be removed rather than sitting unimplemented, and ADR-0005's history reasoning needs an honest caveat.
* **SQLite/Postgres via Ecto** — what SPEC-0001 assumed. Gives topology + history + drift in one place; adds a dependency and a migration story. Postgres already runs on ie01, but binnacle is a container that currently has no database, and adding one changes the deployment shape.
* **A time-series store** — the readings are timestamped numeric samples, which is what Prometheus/VictoriaMetrics/Beszel already do well. Binnacle should read from one rather than own storage; making it the owner duplicates existing infrastructure.

## Decision Outcome

Chosen option: **DETS for crash survival**. The Fleet GenServer opens a DETS table on boot (`:dets.open_file/2`) and writes the history list per host on every sample tick. On restart, the table is read back to seed the in-memory history before the first tick. The table is owned by the Fleet process and closed on termination.

This is deliberately not a database:
- **No Ecto, no SQLite, no Postgres.** The data is a capped list of samples per host key — a key-value map, not a relational schema. DETS is the right shape.
- **No long-term retention.** The table holds the same 120 samples the in-memory history holds. "Was ogma this hot last week" is a question for the Prometheus/Beszel stack that already watches the fleet, not for binnacle. A future story that wants binnacle to answer retention questions should wire it as a *reader* of that stack, not as an owner of a competing one.
- **No schema migrations.** The table is a flat `{host_key, [Sample.t()]}` set. If the sample struct changes, the table is rebuilt from an empty state on the next boot — the same state a fresh deploy produces today.

SPEC-0001's "Database Operation Standards" requirement is **amended**: the atomic-per-cycle write becomes a single `:dets.insert/2` per host per tick (which is atomic by construction), and the "parameterized statements" and "schema init on empty database" clauses are withdrawn — they describe a relational database, and the decision is not to use one. The spec should be updated to match.

### Consequences

* Good, because a restart restores the last 10 minutes of trend data instead of wiping it — the worst symptom is removed with the cheapest possible change.
* Good, because no new dependency is added: DETS is in the BEAM standard library, and the Fleet GenServer already owns the state.
* Good, because binnacle stays a lightweight container with no database to migrate, back up, or recover.
* Good, because the decision is honest about scope: binnacle is a live overview, not an archive, and the retention question is answered by pointing at the existing Prometheus/Beszel stack rather than duplicating it.
* Bad, because DETS has no concurrent writer support — only one process can write at a time. The Fleet GenServer is already the single serialization point, so this is not a constraint in practice, but it is a property to know.
* Bad, because DETS tables are not replicated — if the container's volume is lost, the history is lost too. This is the same failure mode as today; DETS only improves the restart case, not the data-loss case.
* Bad, because "was ogma this hot last week" still cannot be answered by binnacle. That is a deliberate scope boundary, not a defect — the fleet already has the tool for that.

## Notes

* The DETS table path should be configurable (`BINNACLE_DATA_DIR`, defaulting to `priv/data`) so the container can mount a volume for it.
* The table should be opened with `file: :read_write` and `auto_save: true` so the Fleet process does not need to manage checkpointing.
* A future story may add a Prometheus/Beszel *reader* to binnacle for long-term trend queries. That reader is a separate concern from the DETS crash-survival table and should not be coupled to it.
* If the retention story grows beyond what a reader provides — alerting, anomaly detection, custom thresholds — that is the point to revisit whether binnacle should own a time-series store. Until then, DETS + a reader is the right shape.
