# hhm-lib-core

Shared, runtime-light libraries for **Hacker House Medellín**.

- `crates/contracts` — stable event, actor, and request metadata contracts
- `crates/persistence` — tenant-, user-, and service-scoped SeaORM reservation persistence
- `crates/platform-schema` — compile witness for the immutable Rust, SeaORM, and Diesel platform projections
- `crates/routing` — deterministic routing and priority classification
- `vendor/hhm-interfaces/platform` — byte-verified platform artifacts from the production interface revision
- `src/` — JavaScript reference implementation for Workers and web tooling
- `schemas/` — JSON Schema documents for language-neutral validation

The persistence crate imports canonical `hhm-interfaces` at immutable revision
`b66988b856946ff028085323ff502796b97e0012`. It does not copy interface
types or authenticate callers. Applications must verify identity and authorize
product membership first, then supply all three product scope dimensions and
an explicit read or create capability. Reads run in PostgreSQL read-only
transactions, every lookup includes record, tenant, user, and service
predicates, and database errors are redacted at the library boundary.

The additive platform migrations adopt the generated `hhm_space_reservations`
model without changing the legacy `hhm_reservations` table. They add PostgreSQL
17 tenant RLS, tenant-aligned foreign keys, reservation capacity and overlap
prevention, compare-and-swap transition functions, append-only transition and
access-decision ledgers, and non-login reader/writer roles. See
[`docs/platform-persistence.md`](docs/platform-persistence.md).

The SeaORM entity is intentionally private. Schema changes belong in reviewed
declarative migrations owned by the deployment path; the library never runs
startup DDL.

```bash
./scripts/test.sh
```

Database witnesses require an explicitly created, empty PostgreSQL 17 database:

```bash
scripts/verify-platform-schema.sh "$FRESH_TEST_DATABASE_URL"
```
