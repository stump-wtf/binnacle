---
status: draft
date: 2026-08-15
implements: [ADR-0003]
---

# SPEC-0002: Service Discovery — Ansible Manifest Enrichment for Containers

## Overview

binnacle enriches Docker-discovered containers with service-layer metadata exported from the StumpCloud Ansible inventory (ADR-0003). The Ansible repo generates a credential-free JSON manifest mapping `(host, container_name)` pairs to structural metadata (DNS, OIDC gating, database backing, homepage grouping, sidecars). binnacle loads this manifest at startup and merges it into the fleet taxonomy's Container entities. Missing or stale manifests degrade gracefully to Docker-only metadata.

## Requirements

### Requirement: Manifest Schema

The system SHALL consume a JSON manifest conforming to the schema defined in ADR-0003. Each entry MUST contain `host`, `container_name`, `service_name`, `dns`, `image`, `port`, and `enabled`. Optional fields (`guest_vmid`, `caddy_vhost`, `oidc_gated`, `has_database`, `database_type`, `homepage_group`, `homepage_description`, `sidecars`, `tags`) SHALL default to null or empty when absent. `guest_vmid` is optional rather than required because the generator cannot always resolve it (see Guest VMID Resolution below); when it is null, enrichment still matches on `(host, container_name)`. The manifest MUST include a `generated_at` ISO 8601 timestamp and an `inventory` source identifier.

#### Scenario: Valid manifest loads successfully

- **WHEN** binnacle starts with a well-formed manifest file
- **THEN** all entries are indexed by `(host, container_name)` and available for enrichment

#### Scenario: Malformed manifest rejected with actionable error

- **WHEN** the manifest file contains invalid JSON or missing required fields
- **THEN** binnacle logs the specific validation failure and continues without enrichment

### Requirement: Credential Exclusion

The manifest MUST NOT contain any credential, secret, password, API key, token, or private key. Fields that carry credentials in the Ansible inventory (`db.pass`, `secrets.*`, `environment.*_PASSWORD`, `environment.*_SECRET`, `environment.*_KEY`, `oidc_client_secret`, Vault lookup expressions) MUST be stripped during manifest generation. The system SHALL treat any field whose name matches known credential patterns as sensitive and exclude it regardless of value.

#### Scenario: Database password excluded from manifest

- **WHEN** the Ansible inventory declares `db.pass` for a service
- **THEN** the manifest entry carries `has_database: true` and `database_type: "postgres"` but no password field

#### Scenario: Environment secrets excluded

- **WHEN** a service declares `environment.CAIRN_S3_SECRET_KEY` in the inventory
- **THEN** the manifest entry omits the field entirely

### Requirement: Container Enrichment Merge

When a Docker-discovered container matches a manifest entry on `(host, container_name)`, the system SHALL merge the manifest metadata into the Container entity. Docker-discovered fields (live status, resource usage, uptime) take precedence over manifest fields when both exist. Manifest fields not present in Docker discovery (DNS, OIDC gating, database backing, homepage metadata) are added.

#### Scenario: Running container enriched with service metadata

- **WHEN** Docker reports container `cairn` on host `ie01` and the manifest has a matching entry
- **THEN** the Container entity carries both Docker live state and manifest service metadata

#### Scenario: Docker fields take precedence

- **WHEN** Docker reports container image `cairn:0.0.3` but the manifest says `cairn:0.0.2-dev.2`
- **THEN** the Container entity shows `cairn:0.0.3` (the live truth)

### Requirement: Unmatched Containers

Containers discovered by Docker that have no manifest entry SHALL render with Docker metadata alone. The system SHALL NOT error, warn loudly, or suppress the container. A subtle visual indicator MAY distinguish enriched containers from unenriched ones.

#### Scenario: Unknown container renders normally

- **WHEN** Docker reports a container not present in the manifest
- **THEN** it appears in the UI with Docker-discovered metadata only

### Requirement: Expected-but-Missing Containers

Manifest entries with `enabled: true` that have no matching Docker-discovered container SHALL surface as "expected but not running" under their guest. This is a config drift signal: Ansible says the service should exist, but Docker says it does not. Entries with `enabled: false` (tombstoned services) SHALL NOT surface as missing.

#### Scenario: Enabled service missing from Docker surfaces as drift

- **WHEN** the manifest lists `cairn` on `ie01` as enabled but Docker reports no such container
- **THEN** the UI shows a "not running" indicator under guest vmid 100

#### Scenario: Tombstoned service does not surface as missing

- **WHEN** the manifest lists `reduit` on `ie01` with `enabled: false`
- **THEN** no "not running" indicator appears

### Requirement: Manifest Staleness

The system SHALL track the manifest's `generated_at` timestamp. When the manifest is older than a configurable threshold (default: 24 hours), the UI SHALL display a staleness indicator. Stale manifests still enrich containers; staleness is informational, not gating.

#### Scenario: Fresh manifest enriches silently

- **WHEN** the manifest was generated within the staleness threshold
- **THEN** enrichment proceeds with no staleness indicator

#### Scenario: Stale manifest enriches with indicator

- **WHEN** the manifest was generated more than 24 hours ago
- **THEN** enrichment proceeds and the UI shows a "manifest stale" indicator

### Requirement: Multi-Inventory Support

The system SHALL support loading manifests from multiple inventories (dub, dtw, pdx). Entries from different inventories are merged by `(host, container_name)`. Duplicate keys across inventories indicate a configuration error and SHALL log a warning; the first-loaded entry wins.

#### Scenario: Two inventories load without conflict

- **WHEN** dub.yaml manifest covers ie01/ie02/pie01/pie02 and dtw.yaml covers lake01/lake02
- **THEN** all entries are indexed and available for enrichment

### Requirement: Core Package Codec

The `packages/core` Gren package (ADR-0001) SHALL include a `ServiceMetadata` type and JSON codec representing the manifest entry schema. Decoding failures MUST produce descriptive errors identifying the malformed field. The type MUST be optional on the Container type — containers without enrichment carry `Nothing`.

#### Scenario: Valid manifest entry decodes

- **WHEN** a manifest entry conforms to the schema
- **THEN** it decodes to a `ServiceMetadata` value

#### Scenario: Invalid entry produces descriptive error

- **WHEN** a manifest entry has `"port": "not-a-number"`
- **THEN** decoding fails with an error naming the `port` field and its invalid value

## Design Notes

### Manifest Generation (Ansible Side)

A playbook in `stumpcloud/ansible` (`playbooks/services/binnacle-manifest.yaml`) renders the inventory and exports the manifest. It runs on the controller (not the target host) because it reads inventory data, not host state. The playbook:

1. Iterates all hosts in the inventory.
2. For each host, iterates all service vars (keys matching known service patterns).
3. Extracts structural fields, strips credentials.
4. Writes the aggregated JSON to a file or stdout.

The manifest is committed to the binnacle repo as `config/service-manifest.json` or served as a CI artifact. Regeneration happens on every Ansible converge or via a scheduled CI job.

### Guest VMID Resolution

The manifest needs `guest_vmid` to link containers to ADR-0002 Guests. The Ansible inventory does not directly declare which VMID a service's container runs inside — it declares the host, and Proxmox discovery provides the host-to-guest mapping. The manifest generator resolves this by:

1. Reading the host's `vm.vmid` from inventory (for single-guest hosts like ie01/ie02).
2. For multi-guest hosts, using the Proxmox API to map containers to guests.
3. Falling back to `null` when resolution fails — binnacle still enriches by host+name.

### Security Review Points

* The manifest generation playbook MUST use `no_log: true` on any task that touches credentials, even transiently.
* The manifest file MUST be world-readable only if it contains no credentials (which it should not). Defense in depth: generate with mode 0644, validate with a pre-commit hook that scans for credential patterns.
* binnacle MUST NOT expose manifest contents through its API beyond what the UI already renders. The API returns enriched Container entities, not raw manifest entries.
