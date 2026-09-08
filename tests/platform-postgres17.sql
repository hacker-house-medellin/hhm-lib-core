\set ON_ERROR_STOP on

BEGIN;

DO $legacy_non_collision$
DECLARE
  columns text[];
  payload text;
BEGIN
  SELECT array_agg(column_name ORDER BY ordinal_position)
  INTO columns
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'hhm_reservations';
  SELECT summary INTO payload
  FROM public.hhm_reservations WHERE id = '11111111-1111-4111-8111-111111111111';
  IF columns IS DISTINCT FROM ARRAY[
      'id', 'tenant_id', 'user_id', 'service_id', 'title', 'summary',
      'member_name', 'space_name', 'starts_at', 'ends_at', 'status',
      'created_at', 'updated_at'
    ]
    OR payload <> 'Must survive platform adoption'
  THEN
    RAISE EXCEPTION 'legacy hhm_reservations was changed by platform adoption';
  END IF;
  IF to_regclass('public.hhm_applications') IS NULL THEN
    RAISE EXCEPTION 'existing intake schema did not coexist with platform adoption';
  END IF;
  IF to_regclass('public.hhm_space_reservations') IS NULL THEN
    RAISE EXCEPTION 'normalized hhm_space_reservations is missing';
  END IF;
END
$legacy_non_collision$;

DO $role_attributes$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname IN ('hhm_platform_reader', 'hhm_platform_writer')
      AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'platform roles are not least privilege';
  END IF;
  IF has_table_privilege('hhm_platform_reader', 'public.hhm_space_reservations', 'INSERT')
    OR has_table_privilege('hhm_platform_writer', 'public.hhm_reservation_transitions', 'INSERT')
    OR has_table_privilege('hhm_platform_writer', 'public.hhm_space_reservations', 'UPDATE')
    OR has_table_privilege('hhm_platform_writer', 'public.hhm_access_decisions', 'DELETE')
  THEN
    RAISE EXCEPTION 'platform roles received a forbidden direct table capability';
  END IF;
  IF NOT has_function_privilege(
      'hhm_platform_writer',
      'public.hhm_transition_reservation(text,uuid,reservation_transition_kind,bigint,uuid,text,text,uuid,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'hhm_platform_reader',
      'public.hhm_transition_reservation(text,uuid,reservation_transition_kind,bigint,uuid,text,text,uuid,timestamp with time zone)',
      'EXECUTE'
    )
  THEN
    RAISE EXCEPTION 'named transition capability grants are incorrect';
  END IF;
END
$role_attributes$;

INSERT INTO public.hhm_organizations (
  id, tenant_id, slug, display_name, status, seat_limit, created_at, updated_at
) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000001', 'tenant:alpha', 'alpha', 'Alpha House', 'active', 20, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000001', 'tenant:beta', 'beta', 'Beta House', 'active', 10, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z');

INSERT INTO public.hhm_locations (
  id, tenant_id, slug, display_name, city, country_code, time_zone, active, created_at, updated_at
) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'tenant:alpha', 'medellin', 'Alpha Medellin', 'Medellin', 'CO', 'America/Bogota', true, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000002', 'tenant:beta', 'bogota', 'Beta Bogota', 'Bogota', 'CO', 'America/Bogota', true, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z');

INSERT INTO public.hhm_accounts (
  id, tenant_id, auth_subject, kind, status, organization_id, display_name, created_at, updated_at
) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000003', 'tenant:alpha', 'shared-auth|alpha', 'organization_member', 'active', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001', 'Alpha Resident', '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000003', 'tenant:beta', 'shared-auth|beta', 'organization_member', 'active', 'bbbbbbbb-bbbb-4bbb-8bbb-000000000001', 'Beta Resident', '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z');

INSERT INTO public.hhm_bookable_spaces (
  id, tenant_id, location_id, code, display_name, kind, capacity, active, created_at, updated_at
) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000004', 'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'MR-1', 'Alpha Meeting Room', 'meeting_room', 8, true, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000004', 'tenant:beta', 'bbbbbbbb-bbbb-4bbb-8bbb-000000000002', 'MR-1', 'Beta Meeting Room', 'meeting_room', 6, true, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z');

INSERT INTO public.hhm_space_reservations (
  id, tenant_id, location_id, space_id, booked_by_account_id, organization_id,
  status, starts_at, ends_at, occupant_count, guest_count, idempotency_key,
  version, created_at, updated_at
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000005', 'tenant:alpha',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',
  'requested', '2026-09-10T14:00:00Z', '2026-09-10T15:00:00Z', 3, 1,
  'alpha-reservation-1', 0, '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'
);

INSERT INTO public.hhm_guest_passes (
  id, tenant_id, reservation_id, issued_by_account_id, guest_reference,
  guest_display_name, guest_contact_digest, status, valid_from, valid_until,
  credential_reference_digest, version, created_at, updated_at
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000006', 'tenant:alpha',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000005', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
  'guest-alpha-1', 'Synthetic Guest', 'contact-digest', 'planned',
  '2026-09-10T13:45:00Z', '2026-09-10T15:15:00Z', 'credential-digest', 0,
  '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'
);

INSERT INTO public.hhm_access_grants (
  id, tenant_id, location_id, space_id, account_id, guest_pass_id,
  reservation_id, status, valid_from, valid_until, provider_reference_digest,
  version, created_at, updated_at
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000007', 'tenant:alpha',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', NULL,
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000005', 'pending',
  '2026-09-10T13:45:00Z', '2026-09-10T15:15:00Z', 'provider-digest', 0,
  '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'
);

INSERT INTO public.hhm_visits (
  id, tenant_id, location_id, reservation_id, guest_pass_id, account_id,
  status, expected_at, checked_in_at, checked_out_at, verification_method,
  created_at, updated_at
) VALUES (
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000008', 'tenant:alpha',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005',
  NULL, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', 'expected',
  '2026-09-10T14:00:00Z', NULL, NULL, 'signed_qr',
  '2026-09-08T00:00:00Z', '2026-09-08T00:00:00Z'
);

SET LOCAL ROLE hhm_platform_reader;
SET LOCAL hhm.tenant_id = 'tenant:alpha';
DO $reader_rls$
DECLARE
  visible integer;
BEGIN
  SELECT count(*) INTO visible FROM public.hhm_organizations;
  IF visible <> 1 THEN
    RAISE EXCEPTION 'reader did not see exactly its tenant';
  END IF;
  BEGIN
    INSERT INTO public.hhm_organizations (
      id, tenant_id, slug, display_name, status, seat_limit, created_at, updated_at
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000099', 'tenant:alpha', 'forbidden', 'Forbidden',
      'active', 1, transaction_timestamp(), transaction_timestamp()
    );
    RAISE EXCEPTION 'reader unexpectedly inserted a row';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$reader_rls$;
SET LOCAL hhm.tenant_id = 'tenant:beta';
DO $reader_other_tenant$
DECLARE
  visible integer;
BEGIN
  SELECT count(*) INTO visible FROM public.hhm_organizations WHERE tenant_id = 'tenant:alpha';
  IF visible <> 0 THEN
    RAISE EXCEPTION 'cross-tenant row leaked through RLS';
  END IF;
END
$reader_other_tenant$;
RESET ROLE;

SET LOCAL ROLE hhm_platform_writer;
SET LOCAL hhm.tenant_id = 'tenant:alpha';
DO $writer_scope$
BEGIN
  BEGIN
    UPDATE public.hhm_space_reservations
    SET status = 'confirmed'
    WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005';
    RAISE EXCEPTION 'writer bypassed reservation CAS';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.hhm_reservation_transitions (
      id, tenant_id, reservation_id, kind, expected_version, actor_account_id,
      idempotency_key, reason_code, occurred_at
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000098', 'tenant:alpha',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000005', 'requested_to_confirmed', 0,
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', 'forbidden-direct-ledger',
      'forbidden_write', transaction_timestamp()
    );
    RAISE EXCEPTION 'writer bypassed the transition function';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.hhm_maintenance_tickets (
      id, tenant_id, location_id, reported_by_account_id, priority, status,
      summary, opened_at, updated_at
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000097', 'tenant:beta',
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-000000000003',
      'normal', 'open', 'Cross tenant write must fail', transaction_timestamp(), transaction_timestamp()
    );
    RAISE EXCEPTION 'writer crossed tenant scope';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO public.hhm_maintenance_tickets (
      id, tenant_id, location_id, reported_by_account_id, priority, status,
      summary, opened_at, updated_at
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000096', 'tenant:alpha',
      'bbbbbbbb-bbbb-4bbb-8bbb-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-000000000003',
      'normal', 'open', 'Tenant-aligned foreign keys must fail closed',
      transaction_timestamp(), transaction_timestamp()
    );
    RAISE EXCEPTION 'writer attached an alpha row to beta parents';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END
$writer_scope$;

SELECT public.hhm_transition_reservation(
  'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005',
  'requested_to_confirmed', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
  'reservation-confirm-1', 'resident_confirmed',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000011', '2026-09-08T01:00:00Z'
);
-- An exact replay is idempotent and does not append a second ledger row.
SELECT public.hhm_transition_reservation(
  'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005',
  'requested_to_confirmed', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
  'reservation-confirm-1', 'resident_confirmed',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000011', '2026-09-08T01:00:00Z'
);

SELECT public.hhm_transition_guest_pass(
  'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000006',
  'planned_to_issued', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
  'guest-issue-1', 'reservation_confirmed',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000012', '2026-09-08T01:01:00Z'
);
SELECT public.hhm_transition_access_grant(
  'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000007',
  'pending_to_active', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
  'grant-activate-1', 'reservation_confirmed',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000013', '2026-09-08T01:02:00Z'
);
SELECT public.hhm_transition_visit(
  'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000008',
  'expected_to_checked_in', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
  'visit-checkin-1', 'entry_verified',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000014', '2026-09-10T14:00:00Z'
);

DO $cas_and_overlap$
BEGIN
  IF (SELECT version FROM public.hhm_space_reservations WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005') <> 1
    OR (SELECT count(*) FROM public.hhm_reservation_transitions WHERE reservation_id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005') <> 1
  THEN
    RAISE EXCEPTION 'reservation CAS or idempotent replay failed';
  END IF;

  BEGIN
    PERFORM public.hhm_transition_reservation(
      'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005',
      'confirmed_to_checked_in', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
      'reservation-stale-1', 'stale_command',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000015', '2026-09-10T14:00:00Z'
    );
    RAISE EXCEPTION 'stale reservation transition succeeded';
  EXCEPTION WHEN serialization_failure THEN NULL;
  END;

  BEGIN
    PERFORM public.hhm_transition_reservation(
      'tenant:alpha', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005',
      'requested_to_confirmed', 0, 'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',
      'reservation-confirm-1', 'different_payload',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000016', '2026-09-08T01:00:00Z'
    );
    RAISE EXCEPTION 'idempotency payload mismatch succeeded';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.hhm_space_reservations (
      id, tenant_id, location_id, space_id, booked_by_account_id, organization_id,
      status, starts_at, ends_at, occupant_count, guest_count, idempotency_key,
      version, created_at, updated_at
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000020', 'tenant:alpha',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',
      'held', '2026-09-10T14:30:00Z', '2026-09-10T15:30:00Z', 2, 0,
      'overlap-must-fail', 0, transaction_timestamp(), transaction_timestamp()
    );
    RAISE EXCEPTION 'active reservation overlap succeeded';
  EXCEPTION WHEN exclusion_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.hhm_space_reservations (
      id, tenant_id, location_id, space_id, booked_by_account_id, organization_id,
      status, starts_at, ends_at, occupant_count, guest_count, idempotency_key,
      version, created_at, updated_at
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000021', 'tenant:alpha',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',
      'requested', '2026-09-11T14:00:00Z', '2026-09-11T15:00:00Z', 8, 1,
      'capacity-must-fail', 0, transaction_timestamp(), transaction_timestamp()
    );
    RAISE EXCEPTION 'over-capacity reservation succeeded';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END
$cas_and_overlap$;

DO $allowed_requires_grant$
BEGIN
  BEGIN
    PERFORM public.hhm_record_access_decision(
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000030', 'tenant:alpha',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', NULL,
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000099', 'allowed', 'matching_active_grant',
      repeat('a', 64), 'access-policy-v1', 'access-no-grant', '2026-09-10T14:01:00Z'
    );
    RAISE EXCEPTION 'allowed decision without an exact grant succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$allowed_requires_grant$;

SELECT public.hhm_record_access_decision(
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000031', 'tenant:alpha',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', NULL,
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000007', 'allowed', 'matching_active_grant',
  repeat('b', 64), 'access-policy-v1', 'access-allowed-1', '2026-09-10T14:01:00Z'
);
SELECT public.hhm_record_access_decision(
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000032', 'tenant:alpha',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003', NULL,
  NULL, 'denied', 'policy_unavailable', repeat('c', 64),
  'access-policy-v1', 'access-denied-1', '2026-09-10T14:02:00Z'
);
RESET ROLE;

DO $append_only$
BEGIN
  BEGIN
    UPDATE public.hhm_reservation_transitions SET reason_code = 'tampered';
    RAISE EXCEPTION 'reservation transition ledger was mutable';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  BEGIN
    UPDATE public.hhm_guest_pass_transitions SET reason_code = 'tampered';
    RAISE EXCEPTION 'guest pass transition ledger was mutable';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  BEGIN
    UPDATE public.hhm_visit_transitions SET reason_code = 'tampered';
    RAISE EXCEPTION 'visit transition ledger was mutable';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  BEGIN
    UPDATE public.hhm_access_grant_transitions SET reason_code = 'tampered';
    RAISE EXCEPTION 'access grant transition ledger was mutable';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
  BEGIN
    UPDATE public.hhm_access_decisions SET policy_version = 'tampered';
    RAISE EXCEPTION 'access decision ledger was mutable';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
  END;
END
$append_only$;

DO $final_state$
BEGIN
  IF (SELECT status FROM public.hhm_guest_passes WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000006') <> 'issued'
    OR (SELECT version FROM public.hhm_guest_passes WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000006') <> 1
    OR (SELECT status FROM public.hhm_access_grants WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000007') <> 'active'
    OR (SELECT version FROM public.hhm_access_grants WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000007') <> 1
    OR (SELECT status FROM public.hhm_visits WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000008') <> 'checked_in'
    OR (SELECT count(*) FROM public.hhm_visit_transitions WHERE visit_id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000008') <> 1
    OR (SELECT count(*) FROM public.hhm_access_decisions WHERE tenant_id = 'tenant:alpha') <> 2
  THEN
    RAISE EXCEPTION 'platform lifecycle or access decision witnesses failed';
  END IF;
END
$final_state$;

ROLLBACK;
