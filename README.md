# hhm-lib-core

Shared, runtime-light libraries for **Hacker House Medellín**.

- `crates/contracts` — stable event, actor, and request metadata contracts
- `crates/persistence` — tenant-, user-, and service-scoped SeaORM reservation persistence
- `crates/routing` — deterministic routing and priority classification
- `src/` — JavaScript reference implementation for Workers and web tooling
- `schemas/` — JSON Schema documents for language-neutral validation

The persistence crate imports canonical `hhm-interfaces` at immutable revision
`4079822762f23d014fe0dd8d138b823c0c0758e5`. It does not copy interface
types or authenticate callers. Applications must verify identity and authorize
product membership first, then supply all three product scope dimensions and
an explicit read or create capability. Reads run in PostgreSQL read-only
transactions, every lookup includes record, tenant, user, and service
predicates, and database errors are redacted at the library boundary.

The SeaORM entity is intentionally private. Schema changes belong in reviewed
declarative migrations owned by the deployment path; the library never runs
startup DDL.

```bash
./scripts/test.sh
```
