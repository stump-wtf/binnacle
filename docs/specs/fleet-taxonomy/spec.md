---
status: draft
date: 2026-08-15
implements: [ADR-0002]
---

# SPEC-0001: Fleet Taxonomy — Model, Baseline Config, and Discovery

## Overview

binnacle's first capability: model StumpCloud as Site → Host → Guest → Container with hardware attachments (ADR-0002), seed it from a baseline JSON config file, enrich it with discovery from UniFi, Proxmox, per-guest Docker probes, and Home Assistant, and expose it through a drill-down UI with hardware metrics at host and guest level. Runs on the Elixir/Phoenix base from ADR-0004 (superseding the Gren base this spec was drafted against).

## Requirements

### Requirement: Containment Hierarchy Model

The system SHALL model the fleet as a four-level containment spine: Site → Host → Guest → Container. Every entity other than Site MUST reference exactly one parent. A Host MUST belong to exactly one Site, and hosts MUST NOT span sites. Guests and containers MUST NOT span parents. When a guest migrates between hosts of a site, the system SHALL re-parent the guest while retaining its identity.

#### Scenario: Host appears under its configured site

- **WHEN** the Proxmox endpoint configured for site "cottage" reports node "pve1"
- **THEN** "pve1" appears exactly once as a Host under site "cottage"

#### Scenario: Guest migration re-parents without duplicating

- **WHEN** guest vmid 101 changes Proxmox node from "pve1" to "pve2" within the same site
- **THEN** the guest appears exactly once, parented to "pve2", retaining vmid 101

#### Scenario: Containers land under their guest

- **WHEN** Docker on guest 101 reports container "caddy"
- **THEN** "caddy" appears exactly once under guest 101

### Requirement: Site Kinds

Each Site MUST declare exactly one kind: `home` or `airbnb`. The UI SHOULD surface the kind as a visible badge on site views.

#### Scenario: Airbnb site rendered with kind badge

- **WHEN** the UI renders a site whose kind is `airbnb`
- **THEN** the site displays an Airbnb badge distinguishing it from home sites

### Requirement: Hardware Attachment Model

Every HardwareDevice MUST attach to exactly one node: either a Host or a Guest. Hardware metrics — usage, consumption, capacity, and temperature — MUST be attributed to the owning node. The UI MUST present hardware inventories at both host level and guest level.

#### Scenario: Passed-through drive reports under its guest

- **WHEN** a physical drive is passed through to guest 102
- **THEN** the drive and its metrics appear under guest 102 and not in the host's direct hardware list

#### Scenario: Host-local sensor reports under the host

- **WHEN** a temperature sensor is exposed by Proxmox on node "pve1" and not passed through
- **THEN** it appears in the host's hardware panel

### Requirement: Baseline Config File

The system MUST load a baseline JSON config file declaring: sites (normalized slug and kind), per-site UniFi gateway reference and API key, hosts (key, dial IP, Proxmox API token, site membership), and exactly one Home Assistant reference per site. Config loading MUST fail fast with actionable errors on: duplicate site slugs, a host referencing an unknown site, a missing or invalid kind, and more than one Home Assistant per site. Credentials declared in the config MUST NOT be exposed through the API, the UI, or logs.

#### Scenario: Invalid membership fails fast

- **WHEN** the config maps host "pve9" to site "garage" and no such site exists
- **THEN** startup fails with an error naming the host and the unknown site

#### Scenario: Duplicate slug rejected

- **WHEN** two sites share the slug "cottage"
- **THEN** startup fails with an error naming the duplicated slug

#### Scenario: Secrets stay out of responses

- **WHEN** any API response, UI view, or log line is produced
- **THEN** it contains no config-declared credential

### Requirement: Proxmox Discovery

For every configured host, the system SHALL discover via the Proxmox API: node inventory and status, guests, storage and disks, hardware sensors where exposed, passthrough assignments, and usage / consumption / capacity / temperature metrics for the host and its guests. Polling cadence SHOULD be configurable. An unreachable host MUST be surfaced as degraded with its last-known state retained and marked stale — never silently dropped.

#### Scenario: Unreachable host degrades visibly

- **WHEN** a configured host's Proxmox API is unreachable for three consecutive polls
- **THEN** the host remains in the tree marked unreachable, its last-known data timestamped stale

#### Scenario: Missing sensor omits metric without failing

- **WHEN** a host exposes no temperature data
- **THEN** temperature is omitted for that host and discovery otherwise succeeds

### Requirement: UniFi Site Discovery

For every site, the system SHALL use the UniFi API with the configured key to confirm gateway presence and collect network-device inventory and gateway health metrics. UniFi discovery MUST NOT create, rename, or re-scope sites; normalized site names come only from config.

#### Scenario: Gateway inventory lands under its site

- **WHEN** UniFi reports the gateway and three switches for site "cottage"
- **THEN** the site view lists four network devices with health metrics for the gateway

### Requirement: Home Assistant Presence

The system SHALL record exactly one Home Assistant per site and SHOULD verify its reachability and version, surfacing presence in the site view. Deep Home Assistant telemetry integration is out of scope.

#### Scenario: HA presence surfaced

- **WHEN** site "cottage"'s Home Assistant answers a reachability probe
- **THEN** the site view shows Home Assistant as reachable

### Requirement: Container Discovery

The system SHALL discover Docker containers per guest — name, image, and status — via a reporting channel local to each guest. A newly started container MUST appear under its guest within one discovery cycle.

#### Scenario: New container appears within a cycle

- **WHEN** a container "redis" starts on guest 101
- **THEN** within one discovery cycle "redis" appears under guest 101 with its status

### Requirement: Discovery Does Not Invent Topology

Discovery MUST NOT create Sites or Hosts. Entities observed outside configured topology MUST be surfaced as config drift.

#### Scenario: UniFi site name mismatch becomes drift

- **WHEN** the UniFi API reports a site name that matches no configured slug
- **THEN** it is surfaced as config drift, and no Site entity is created

### Requirement: Read-Only API Surface

The system SHALL expose the taxonomy over JSON HTTP endpoints using the shared wire-contract codecs from `packages/core`. All data endpoints MUST require authentication; only `/healthz` is public.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | /api/sites | Required | List sites with kind and health rollup |
| GET | /api/sites/{slug} | Required | Site detail: hosts, network devices, HA presence |
| GET | /api/hosts/{key} | Required | Host detail: guests, hardware, metrics |
| GET | /api/guests/{id} | Required | Guest detail: containers, hardware, metrics |
| GET | /healthz | Public | Liveness — required for container orchestration probes |

#### Scenario: Unauthenticated request rejected

- **WHEN** a request to `/api/sites` arrives without valid credentials
- **THEN** the server responds 401 and no taxonomy data is returned

#### Scenario: Health check stays public

- **WHEN** an unauthenticated probe hits `/healthz`
- **THEN** the server responds with liveness status

### Requirement: Hierarchy Navigation

The SPA MUST provide drill-down navigation: sites list → site detail (hosts, UniFi devices, HA presence) → host detail (guests, host hardware) → guest detail (containers, passed-through hardware). Every hardware-bearing view MUST include a hardware panel showing usage, consumption, capacity, and temperature where available. Degraded or unreachable states MUST be visible during navigation.

#### Scenario: Full drill-down

- **WHEN** the operator selects site "cottage", then host "pve1", then guest 101
- **THEN** containers and passed-through hardware for guest 101 are displayed, with each step reachable in one selection

#### Scenario: Degraded state visible mid-drill-down

- **WHEN** host "pve2" is unreachable and the operator navigates into it
- **THEN** its last-known guests are shown with a stale/unreachable indicator

### Requirement: Error Handling Standards

All error-producing operations MUST follow structured error handling:

- Errors MUST be wrapped with contextual information at each layer boundary (e.g., "failed to poll host pve1: Proxmox API unreachable: connection refused")
- Silent error swallowing MUST NOT occur — every error MUST be either returned to the caller, logged with sufficient context, or explicitly handled with a documented reason for suppression
- Integration failures MUST degrade the affected entity only, never the whole inventory
- Structured logging MUST be used for error reporting (key-value pairs, not string interpolation)

#### Scenario: Single integration failure degrades one entity

- **WHEN** the UniFi API for site "cottage" fails while all other integrations succeed
- **THEN** only site "cottage"'s network-device data is marked degraded; all other data remains fresh

### Requirement: Concurrency Safety

All concurrent operations MUST follow safe concurrency patterns:

- Poller lifecycle MUST be explicitly managed — every discovery poller MUST have clean startup and graceful shutdown sequences
- Shared inventory state MUST be updated through a single serialization point in the TEA `update` function — pollers emit messages, they do not mutate state directly
- Concurrent API requests MUST observe a consistent inventory snapshot

#### Scenario: Shutdown drains pollers

- **WHEN** the server shuts down while discovery polls are in flight
- **THEN** pollers stop issuing new requests and in-flight results are discarded without corrupting the inventory

### Requirement: Persistence — Crash Survival via DETS

> **Amended 2026-08-21 by ADR-0007.** The original "Database Operation Standards" requirement assumed a relational database (Ecto/SQLite/Postgres). ADR-0007 decided against that: binnacle persists the last N samples per host to a DETS table for crash survival, not a database. The clauses about parameterized statements and schema init are withdrawn — they describe a database the decision is not to use. The atomic-write clause survives, restated below for the DETS shape.

- The per-host history MUST be written to a DETS table on every sample tick so a restart restores the trend window
- The write per host per tick MUST be atomic — a failure mid-write leaves the prior history intact
- The table MUST tolerate startup against a nonexistent file by creating it
- Long-term retention ("was this host hot last week") is out of scope — the fleet's Prometheus/Beszel stack owns that, not binnacle

#### Scenario: History survives a restart

- **WHEN** binnacle restarts
- **THEN** the trend lines show the last N samples from before the restart, not an empty window

## Security Requirements

This spec is web-facing. The following are mandatory.

### Authentication

All `/api/*` endpoints MUST require authentication. For the initial release a single-operator bearer token, loaded from an environment variable (never from the baseline config file, never logged), MUST be accepted; a dedicated authentication/exposure model is a planned follow-up ADR. Token comparison MUST be constant-time. Failed authentication MUST return 401 without distinguishing "missing" from "invalid".

### Rate Limiting

The API MUST apply per-client rate limiting sufficient to protect the upstream integration APIs (Proxmox, UniFi) from request amplification. `/healthz` MAY be exempt.

### Security Headers

All responses MUST set: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, and a `Content-Security-Policy` that disallows inline scripts in the SPA.

### Request Body Size Limits

The API MUST reject request bodies over 1 MB. Data endpoints are read-only and MUST reject non-GET methods on `/api/*` with 405.

### CSRF Protection

Authentication uses bearer tokens (not cookies), so browser-initiated cross-site requests cannot carry credentials; CSRF risk is structurally mitigated. If cookie-based auth arrives in the follow-up ADR, CSRF protection MUST be added then.

### Redirect Validation

The API MUST NOT issue redirects based on user-supplied URLs. Any future redirect-generating endpoint MUST validate targets against an allowlist.

## Accessibility Requirements

This spec involves user-facing UI. The following are MANDATORY per WCAG 2.1 AA.

### WCAG 2.1 AA Compliance

All UI components produced by this spec MUST meet WCAG 2.1 Level AA conformance as the minimum accessibility target.

### ARIA Landmarks

Page structure elements MUST include ARIA landmark roles: `role="banner"` on the site header, `role="navigation"` on navigation regions, `role="main"` on the primary content area, `role="contentinfo"` on the site footer.

### Icon-Only Controls

All icon-only controls (buttons, links) that have no visible text label MUST include an `aria-label` attribute describing the control's purpose.

### Dynamic Content Regions

Dynamically updated content (metric refreshes, degraded-state indicators, discovery updates) MUST use `aria-live` regions: `aria-live="polite"` for non-urgent updates, `aria-live="assertive"` for critical status changes.

### Keyboard Navigation

All interactive elements MUST be operable via keyboard: logical tab order following visual layout, Enter/Space to activate controls, Escape to dismiss popups and dropdowns, Arrow keys for navigation within composite widgets (the site → host → guest → container drill-down tree).

### Focus Management

Modals and dialogs MUST implement focus management: focus trapped within the modal when open, focus moved to the modal's first focusable element on open, focus returned to the triggering element on close.
