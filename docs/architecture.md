# Architecture

`hhm-lib-core` contains reusable community, application, stay, room, event,
project, authorization, persistence, serialization, and routing helpers.

## Canonical package boundary

- `hhm-interfaces` owns wire formats and generated contract types.
- `hhm-lib-core` consumes interfaces and owns reusable product behavior and
  scoped SeaORM persistence.
- `hhm-clients` exposes versioned SDKs built on the interface contracts.
- `hhm-sync` owns offline-first reconciliation.
- API, web, and CLI repositories compose these packages rather than copying their source.

The long `hacker-house-medellin-libs` repository is a historical bootstrap alias, not a package source. Its generic two-field `Record` scaffold is intentionally not migrated because it duplicates neither the canonical domain model nor production behavior.

## Zed and Git submodules

Use `hacker-house-medellin/hhm-lib-core` as the canonical Zed coordinate. The
long `hhm-libs` name is retained only as migration history. A retained Git
submodule must have an explicit editable-workspace, inventory, embedded-source,
experiment-reference, or legacy role; do not resolve the same repository
through both Zed and a gitlink in one composition.

`zed overtake --git-submodules` imports each initialized submodule that declares its own `.zpkg.toml` into the root manifest and lockfile, retains `.gitmodules` as a reversible transport mirror, and records the exact gitlink commit.

## Persistence authorization boundary

Shared Auth establishes the verified user identity and calling service;
product-owned authorization establishes the tenant membership and reservation
capability. `hhm-persistence` accepts all three identifiers together and never
infers one from another. Missing, malformed, or unauthorized dimensions fail
before database access. Read queries run inside an explicit PostgreSQL
read-only transaction and include tenant, user, service, and record predicates.

`hhm-interfaces` remains the source of truth for reservation wire and domain
types. The Cargo dependency is pinned to immutable reviewed revision
`4079822762f23d014fe0dd8d138b823c0c0758e5`; database-only scope columns stay
inside this library rather than leaking into the public interface contract.
