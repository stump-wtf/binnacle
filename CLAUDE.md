# binnacle

**binnacle is StumpCloud's fleet monitor** — sites → hosts → VMs → containers
with hardware metrics, built as a Gren full-stack application (browser SPA +
Node server + shared core). See [docs/adrs/](docs/adrs/) and
[docs/specs/](docs/specs/).

## Architecture Context

- Architecture Decision Records are in docs/adrs/
- Specifications are in docs/specs/
- ADR-0001 defines the Gren monorepo base stack; ADR-0002 defines the fleet
  taxonomy that SPEC-0001 implements

This project follows **spec-driven development** (the `sdd` plugin). Read the
ADRs and specs before proposing structural changes. When implementing code
governed by a spec, leave a governing comment:
`// Governing: ADR-XXXX (desc), SPEC-XXXX REQ "…"`.

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
