# Vendored platform contract

These four files are byte-for-byte copies of the parity-checked platform
artifacts published by `hacker-house-medellin/hhm-interfaces` at production
revision `b66988b856946ff028085323ff502796b97e0012`.

Do not edit them here. Change the two independent interface authorities, pass
their generation and parity gates, publish a new immutable interface revision,
then deliberately revendor it. `SOURCE.json` records each byte length and
SHA-256 digest. `scripts/verify-platform-vendor.py` verifies those digests, the
generated SQL migration copy, the Cargo pin, and—when given an interface
checkout—the exact upstream revision and file bytes.

The generated SQL creates the portable platform objects. The separately
reviewed additive hardening migration owns PostgreSQL-specific RLS, exclusion
constraints, compare-and-swap functions, immutable ledgers, and grants.
