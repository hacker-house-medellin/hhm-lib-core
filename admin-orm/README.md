# Admin ORM boundary

This package is the named administrative database surface owned by
`hhm-lib-core`. The sibling admin API and admin web server import it through the
repository's Zed coordinate and compile this Rust package from the same reviewed
revision.

The web server receives only `AdminReadContext`, which rejects a credential
unless PostgreSQL reports `transaction_read_only=on`. The API receives
`AdminWriteContext`, which rejects a read-only credential. Neither context
exposes its SeaORM connection, and consumers cannot submit arbitrary SQL.

`schema/admin-db-contract.sql` is the declarative authority owned by product
lib-core and applied only by deployment tooling. This package
performs only the named readiness, grant, dashboard, and idempotent action
operations required by the isolated admin plane; it never runs migrations.
At connection time the adapter also verifies the exact configured PostgreSQL host,
database, and role, requires `sslmode=verify-full`, and rejects superuser,
role-management, database-creation, replication, row-security-bypass, and DDL-capable
credentials. Pool sizes and timeouts are deliberately bounded.

Idempotent writes bind a key to the full actor/session/action payload. A changed
payload returns a conflict instead of replaying another administrator's result. Each
accepted action writes its durable audit outbox event in the same transaction.
Workers claim events with expiring, token-fenced leases. A late completion cannot
overwrite a reclaimed action, and retryable failures use bounded backoff before a
terminal dead-letter state.

## Formal state-machine gate

`../formal/admin-action-queue/` contains an executable TLA+ abstraction of the request/outbox lifecycle. Hosted TLC checks request/outbox coherence, attempt bounds, lease ownership, monotonic fencing, stale-completion non-mutation, retry escalation, and terminal closure. The model is bound to the exact Git blobs of this Rust module and its declarative PostgreSQL constraint file, so implementation drift fails closed until the model is reviewed and advanced.

The finite model complements the existing Rust/PostgreSQL integration tests; it does not replace database isolation, authorization, worker identity, or deployed-service acceptance.
