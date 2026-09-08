# Platform persistence v1

## Immutable source and generated projections

This repository consumes production `hacker-house-medellin/hhm-interfaces`
revision `b66988b856946ff028085323ff502796b97e0012`. The generated SQL, Rust,
SeaORM, and Diesel projections are copied byte-for-byte under
`vendor/hhm-interfaces/platform`; `SOURCE.json` records their sizes and SHA-256
digests. The generated SQL migration is also byte-identical to that SQL lane.

`scripts/verify-platform-vendor.py` checks the local digests, the Cargo pin and
lock resolution, and the generated migration copy. Hosted CI checks out the
exact upstream SHA and byte-compares all four artifacts. The
`hhm-platform-schema` crate compiles the three Rust-family projections. No
generated file is edited to encode product behavior.

## Additive migration ownership

Apply these files once and in order through the reviewed deployment migration
path, never from application startup:

1. `202609080001_hhm_platform_generated.sql` creates the portable generated
   types, tables, indexes, and foreign keys.
2. `202609080002_hhm_platform_hardening.sql` adds PostgreSQL-specific
   invariants, tenant policy, named functions, and grants.

Both are additive. The generated normalized reservation table is
`hhm_space_reservations`; the pre-existing, incompatible `hhm_reservations`
table remains a separate legacy boundary. The PostgreSQL witness deliberately
creates a legacy table first and proves its columns and data survive unchanged.
Roll forward with a reviewed additive migration. Do not roll back by dropping
types, tables, constraints, roles, functions, or customer data.

## Transactional invariants

Every generated platform table enables and forces RLS. A caller must set the
transaction-local `hhm.tenant_id`; policies compare it to each row's
`tenant_id`. Composite tenant foreign keys prevent an authorized writer from
attaching its row to another tenant's location, account, space, reservation,
guest pass, access grant, or visit.

The database additionally enforces:

- positive organization seat and space capacity;
- ordered reservation, guest, access, network, and housekeeping windows;
- positive reservation occupancy within the active space capacity;
- no overlapping `held`, `confirmed`, or `checked_in` reservation for the same
  tenant and space, using half-open time ranges;
- exact-account-or-guest principal shape for visits, grants, and decisions;
- compare-and-swap state edges and expected versions for reservation, guest
  pass, access grant, and visit transitions;
- exact-payload idempotency replay and rejection of key reuse with changed
  payloads;
- append-only reservation, guest, visit, access-grant transition ledgers and
  access-decision ledger; and
- an `allowed` decision only for an exact active grant, principal, location,
  space, validity window, and matching-active-grant reason.

The immutable v1 `Visit` interface has no aggregate `version` column although
its transition has `expectedVersion`. Visit CAS therefore locks the visit row
and compares `expectedVersion` to the append-only transition count. That choice
preserves the published interface while still serializing concurrent commands.

## Least-privilege database capabilities

`hhm_platform_reader` and `hhm_platform_writer` are non-login, non-inheriting,
non-superuser roles without database, role, replication, or RLS-bypass powers.
Infrastructure may grant one of them to a separately managed application login.

- both roles may select only rows admitted by tenant RLS;
- the reader has no writes;
- the writer may create lifecycle aggregates but cannot update them directly;
- lifecycle updates and ledger inserts require the four named CAS functions;
- access-decision inserts require `hhm_record_access_decision`; and
- neither role has DELETE or DDL authority.

`hhm-orm-core` must expose these as named tenant-scoped capabilities, remain
read-only by default, and require its `read-write` feature plus a typed
`WriteContext` for mutations. It must not expose a raw connection, generic SQL,
generic CRUD, migrations, or startup DDL.

## Acceptance boundary

CI creates an explicit fresh PostgreSQL 17 database and lets the service
container teardown reclaim it; the scripts never issue `DROP`, `TRUNCATE`, or
unbounded `DELETE`. Witnesses cover RLS isolation, denied direct writes,
cross-tenant denial, capacity, overlap, CAS, stale commands, idempotency,
fail-closed access decisions, append-only ledgers, grants, and legacy-table
non-collision.

This repository does not establish live database acceptance. Production and
admin Neon connectivity, migration application, role membership, runtime
queries, and provider read-back remain independent deployment gates. An admin
database that is disabled or blocks both public and VPC access is a closed
gate, not a successful test.
