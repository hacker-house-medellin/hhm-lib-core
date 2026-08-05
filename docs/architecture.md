# Architecture

`hhm-libs` contains reusable community, application, stay, room, event, project, authorization, serialization, and routing helpers.

## Canonical package boundary

- `hhm-interfaces` owns wire formats and generated contract types.
- `hhm-libs` consumes interfaces and owns reusable, runtime-light behavior.
- `hhm-clients` exposes versioned SDKs built on the interface contracts.
- `hhm-sync` owns offline-first reconciliation.
- API, web, and CLI repositories compose these packages rather than copying their source.

The long `hacker-house-medellin-libs` repository is a historical bootstrap alias, not a package source. Its generic two-field `Record` scaffold is intentionally not migrated because it duplicates neither the canonical domain model nor production behavior.

## Zed and Git submodules

Use `hacker-house-medellin/hhm-libs` as the only Zed coordinate. A retained Git submodule must have an explicit editable-workspace, inventory, embedded-source, experiment-reference, or legacy role; do not resolve the same repository through both Zed and a gitlink in one composition.

`zed overtake --git-submodules` imports each initialized submodule that declares its own `.zpkg.toml` into the root manifest and lockfile, retains `.gitmodules` as a reversible transport mirror, and records the exact gitlink commit.
