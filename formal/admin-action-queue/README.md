# Admin action queue formal model

`AdminActionQueue.tla` is an executable TLA+ abstraction of the isolated admin action request and transactional outbox implementation in `admin-orm`.

## Checked behavior

TLC exhaustively explores a finite retry and lease domain and checks:

- request and outbox status coherence;
- a delivering action has exactly one current lease and every other state has none;
- claim and reclaim increment the attempt count and issue a strictly newer fencing token;
- an expired lease can be reclaimed only below the lease-attempt ceiling;
- stale completion attempts cannot mutate the request, delivery state, attempt count, current token, expiry state, or terminal marker;
- retryable failures return to the accepted/failed pair below the retry ceiling and become failed/dead-letter at or above it;
- delivered and dead-letter records never reopen.

The checked constants `MaxRetryableFailures = 2` and `MaxLeaseAttempts = 3` are finite abstractions of the production Rust limits `10` and `100`. The source-binding gate pins the complete Rust implementation and PostgreSQL constraint authority, so a limit or transition change invalidates the evidence until the model and binding are reviewed together.

## Limits

This is a bounded proof of the declared queue abstraction. It is not a mechanical refinement proof of Rust or SQL, and it does not certify PostgreSQL transaction isolation, `FOR UPDATE SKIP LOCKED`, worker identity, authorization, network delivery, or a deployed service. Existing Rust and PostgreSQL integration tests remain required.

## Run

With Java 21 and network access:

```sh
bash scripts/formal-admin-action-check.sh
```

An already verified TLA+ tools JAR can be supplied through `TLA_TOOLS_JAR`. The script verifies both SHA-1 and SHA-256 before use and writes a digest-bearing receipt under `target/formal-admin-action/`.
