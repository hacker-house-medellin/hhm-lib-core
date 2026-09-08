#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
node --test tests/*.test.mjs
node --check src/index.mjs
python3 -m json.tool schemas/event-envelope.schema.json >/dev/null
python3 scripts/verify-platform-vendor.py
if command -v cargo >/dev/null 2>&1; then
  cargo fmt --all -- --check
  cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
  cargo test --workspace --all-targets --all-features --locked
  # SQLx declares its optional MySQL driver in package metadata, so Cargo.lock
  # contains rsa even though this workspace enables only PostgreSQL. Fail if
  # rsa ever becomes reachable before applying the narrow lockfile exception.
  if cargo tree --locked --target all -i rsa 2>/dev/null | grep -q '^rsa '; then
    printf '%s\n' 'audit: rsa became reachable in the enabled dependency graph' >&2
    exit 1
  fi
  cargo audit --ignore RUSTSEC-2023-0071
fi
