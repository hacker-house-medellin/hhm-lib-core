#!/usr/bin/env bash
set -euo pipefail

database_url=${1:?usage: scripts/verify-platform-schema.sh <fresh-postgres-17-database-url>}
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

server_version=$(psql "$database_url" -X --tuples-only --no-align --set ON_ERROR_STOP=1 \
  --command "SHOW server_version_num")
if [[ ! "$server_version" =~ ^17[0-9]{4}$ ]]; then
  printf '%s\n' 'platform schema witness requires PostgreSQL 17' >&2
  exit 1
fi

user_table_count=$(psql "$database_url" -X --tuples-only --no-align --set ON_ERROR_STOP=1 \
  --command "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')")
if [[ "$user_table_count" != "0" ]]; then
  printf '%s\n' 'platform schema witness refuses a database that is not fresh' >&2
  exit 1
fi

# Materialize the existing intake authority, then deliberately create the
# incompatible historical reservation table. Both platform migrations must
# coexist with the current schema and leave the legacy columns and data intact.
psql "$database_url" -X --set ON_ERROR_STOP=1 \
  --file "$repo_dir/schema/schema.sql" >/dev/null
psql "$database_url" -X --set ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE public.hhm_reservations (
  id uuid PRIMARY KEY,
  tenant_id text NOT NULL,
  user_id text NOT NULL,
  service_id text NOT NULL,
  title text NOT NULL,
  summary text NOT NULL,
  member_name text NOT NULL,
  space_name text NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  status text NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);
INSERT INTO public.hhm_reservations (
  id, tenant_id, user_id, service_id, title, summary, member_name, space_name,
  starts_at, ends_at, status, created_at, updated_at
) VALUES (
  '11111111-1111-4111-8111-111111111111', 'legacy-tenant', 'legacy-user',
  'hhm-api-server.rs', 'Legacy reservation', 'Must survive platform adoption',
  'Synthetic Resident', 'Legacy Room', '2026-09-08T10:00:00Z',
  '2026-09-08T11:00:00Z', 'requested', '2026-09-08T00:00:00Z',
  '2026-09-08T00:00:00Z'
);
SQL

psql "$database_url" -X --set ON_ERROR_STOP=1 --single-transaction \
  --file "$repo_dir/migrations/202609080001_hhm_platform_generated.sql" >/dev/null
psql "$database_url" -X --set ON_ERROR_STOP=1 \
  --file "$repo_dir/migrations/202609080002_hhm_platform_hardening.sql" >/dev/null
psql "$database_url" -X --set ON_ERROR_STOP=1 \
  --file "$repo_dir/tests/platform-postgres17.sql" >/dev/null

printf '%s\n' 'PostgreSQL 17 platform schema witnesses passed'
