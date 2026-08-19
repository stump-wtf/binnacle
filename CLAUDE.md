# binnacle

**binnacle is StumpCloud's fleet monitor** — sites → hosts → VMs → containers
with hardware metrics over time, built as an Elixir/Phoenix LiveView
application (ADR-0004). See [docs/adrs/](docs/adrs/) and
[docs/specs/](docs/specs/).

## Architecture Context

- Architecture Decision Records are in docs/adrs/
- Specifications are in docs/specs/
- ADR-0004 defines the Elixir full-stack base (superseding ADR-0001's Gren
  base); ADR-0002 defines the fleet taxonomy that SPEC-0001 implements;
  ADR-0005 defines the hardware-metrics zen overview

This project follows **spec-driven development** (the `sdd` plugin). Read the
ADRs and specs before proposing structural changes. When implementing code
governed by a spec, leave a governing comment:
In Elixir: `# Governing: ADR-XXXX (desc), SPEC-XXXX REQ "…"`. In HEEx, put it in the component moduledoc.

## SDD Configuration

### Tracker
- **Type**: gitea
- **Owner**: stump.wtf
- **Repo**: binnacle

### Branch Conventions
- **Enabled**: true
- **Prefix**: feature
- **Epic Prefix**: epic
- **Slug Max Length**: 50

### PR Conventions
- **Enabled**: true
- **Close Keyword**: Closes
- **Ref Keyword**: Part of
- **Include Spec Reference**: true
