#!/usr/bin/env bash
set -euo pipefail

database_url=${1:?usage: scripts/verify-intake-schema.sh <database-url> [schema-or-migration-file ...]}
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
shift
if [[ $# -eq 0 ]]; then
  set -- "$repo_dir/schema/schema.sql"
fi

for ddl_file in "$@"; do
  psql "$database_url" -X --set ON_ERROR_STOP=1 --file "$ddl_file" >/dev/null
done

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
  account_id uuid;
BEGIN
  SELECT id, balance, lifetime_earned
  INTO account_id, current_balance, current_lifetime
  FROM hhm_user_points_accounts
  WHERE subject = 'ci-subject';

  IF account_id IS NULL OR current_balance <> 15 OR current_lifetime <> 25 THEN
    RAISE EXCEPTION 'points trigger did not materialize the expected account state';
  END IF;
END
$verify_points$;

DO $verify_application_fence$
DECLARE
  application_columns integer;
BEGIN
  SELECT count(*)
  INTO application_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'hhm_applications'
    AND column_name IN ('status_version', 'last_admin_operation_id');

  IF application_columns <> 2 THEN
    RAISE EXCEPTION 'application admin-transition fence columns are missing';
  END IF;
END
$verify_application_fence$;

DO $verify_application_placement$
DECLARE
  placement_columns integer;
  placement_constraints integer;
BEGIN
  SELECT count(*)
  INTO placement_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'hhm_applications'
    AND column_name IN (
      'allergy_notes',
      'noise_sensitivity',
      'light_sensitivity',
      'room_preference_notes',
      'roommate_preference',
      'preferred_room_occupancy',
      'roommate_for_lower_cost',
      'roommate_for_social_connection',
      'accommodation_data_consent'
    );

  SELECT count(*)
  INTO placement_constraints
  FROM pg_constraint
  WHERE conrelid = 'public.hhm_applications'::regclass
    AND conname IN (
      'hhm_applications_noise_sensitivity',
      'hhm_applications_light_sensitivity',
      'hhm_applications_roommate_preference',
      'hhm_applications_room_occupancy',
      'hhm_applications_accommodation_consent'
    );

  IF placement_columns <> 9 OR placement_constraints <> 5 THEN
    RAISE EXCEPTION 'application placement columns or constraints are missing';
  END IF;
END
$verify_application_placement$;

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
