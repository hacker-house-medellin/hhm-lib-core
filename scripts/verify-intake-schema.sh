#!/usr/bin/env bash
set -euo pipefail

database_url=${1:?usage: scripts/verify-intake-schema.sh <database-url> [schema-or-migration-file]}
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ddl_file=${2:-$repo_dir/schema/schema.sql}

psql "$database_url" -X --set ON_ERROR_STOP=1 --file "$ddl_file" >/dev/null

psql "$database_url" -X --set ON_ERROR_STOP=1 <<'SQL'
BEGIN;

INSERT INTO hhm_user_points_ledger (
  subject,
  delta,
  reason_code,
  source_submission_id,
  idempotency_key,
  actor_subject
) VALUES (
  'ci-subject',
  25,
  'application_submitted',
  gen_random_uuid(),
  'ci-points-entry',
  'ci-admin'
);

INSERT INTO hhm_user_points_ledger (
  subject,
  delta,
  reason_code,
  source_submission_id,
  idempotency_key,
  actor_subject
) VALUES (
  'ci-subject',
  -10,
  'application_credit_redeemed',
  gen_random_uuid(),
  'ci-points-redemption',
  'ci-admin'
);

DO $verify_points$
DECLARE
  current_balance bigint;
  current_lifetime bigint;
BEGIN
  SELECT balance, lifetime_earned
  INTO current_balance, current_lifetime
  FROM hhm_user_points_accounts
  WHERE subject = 'ci-subject';

  IF current_balance <> 15 OR current_lifetime <> 25 THEN
    RAISE EXCEPTION 'points trigger did not materialize the expected account state';
  END IF;
END
$verify_points$;

DO $verify_overdraw$
BEGIN
  BEGIN
    INSERT INTO hhm_user_points_ledger (
      subject,
      delta,
      reason_code,
      idempotency_key,
      actor_subject
    ) VALUES (
      'ci-subject',
      -16,
      'application_credit_overdraw',
      'ci-points-overdraw',
      'ci-admin'
    );
    RAISE EXCEPTION 'points ledger unexpectedly permitted a negative balance';
  EXCEPTION
    WHEN check_violation THEN
      NULL;
  END;
END
$verify_overdraw$;

DO $verify_immutable$
BEGIN
  BEGIN
    UPDATE hhm_user_points_ledger
    SET delta = 50
    WHERE idempotency_key = 'ci-points-entry';
    RAISE EXCEPTION 'points ledger mutation unexpectedly succeeded';
  EXCEPTION
    WHEN SQLSTATE '55000' THEN
      NULL;
  END;
END
$verify_immutable$;

CREATE ROLE hhm_schema_probe NOLOGIN;
GRANT USAGE ON SCHEMA public TO hhm_schema_probe;
GRANT SELECT, INSERT ON hhm_pre_interests TO hhm_schema_probe;
SET LOCAL ROLE hhm_schema_probe;

DO $verify_rls$
BEGIN
  BEGIN
    INSERT INTO hhm_pre_interests (
      email,
      linkedin_url,
      entrepreneurship_idea,
      stay_preference,
      idempotency_key,
      payload_sha256,
      privacy_notice_version,
      source_host
    ) VALUES (
      'probe@example.com',
      'https://www.linkedin.com/in/probe',
      'A sufficiently detailed entrepreneurship idea for an RLS denial check.',
      'three_months',
      'ci-rls-entry',
      repeat('a', 64),
      'ci-v1',
      'ci.hhaus.org'
    );
    RAISE EXCEPTION 'untrusted database role unexpectedly bypassed intake RLS';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$verify_rls$;

RESET ROLE;
ROLLBACK;
SQL
