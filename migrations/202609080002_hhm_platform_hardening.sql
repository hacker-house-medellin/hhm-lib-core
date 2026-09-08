-- Reviewed additive PostgreSQL 17 hardening for the platform schema generated
-- by hhm-interfaces revision b66988b856946ff028085323ff502796b97e0012.
--
-- Apply 202609080001 first. Migration runners must apply each file once in a
-- transaction. This file intentionally contains no destructive DDL and never
-- touches the legacy public.hhm_reservations table.

BEGIN;

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
SET LOCAL search_path = pg_catalog, public;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hhm_platform_reader') THEN
    CREATE ROLE hhm_platform_reader
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'hhm_platform_reader'
      AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'existing hhm_platform_reader role has unsafe attributes';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hhm_platform_writer') THEN
    CREATE ROLE hhm_platform_writer
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'hhm_platform_writer'
      AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'existing hhm_platform_writer role has unsafe attributes';
  END IF;
END
$roles$;

ALTER TABLE public.hhm_organizations
  ADD CONSTRAINT hhm_organizations_seat_limit_positive CHECK (seat_limit > 0),
  ADD CONSTRAINT hhm_organizations_tenant_id_identity UNIQUE (tenant_id, id);

ALTER TABLE public.hhm_locations
  ADD CONSTRAINT hhm_locations_tenant_id_identity UNIQUE (tenant_id, id);

ALTER TABLE public.hhm_accounts
  ADD CONSTRAINT hhm_accounts_tenant_id_identity UNIQUE (tenant_id, id),
  ADD CONSTRAINT hhm_accounts_tenant_organization_fkey
    FOREIGN KEY (tenant_id, organization_id)
    REFERENCES public.hhm_organizations (tenant_id, id);

ALTER TABLE public.hhm_bookable_spaces
  ADD CONSTRAINT hhm_bookable_spaces_capacity_positive CHECK (capacity > 0),
  ADD CONSTRAINT hhm_bookable_spaces_tenant_id_identity UNIQUE (tenant_id, id),
  ADD CONSTRAINT hhm_bookable_spaces_tenant_location_identity UNIQUE (tenant_id, location_id, id),
  ADD CONSTRAINT hhm_bookable_spaces_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id);

ALTER TABLE public.hhm_space_reservations
  ADD CONSTRAINT hhm_space_reservations_window CHECK (starts_at < ends_at),
  ADD CONSTRAINT hhm_space_reservations_occupants CHECK (occupant_count > 0 AND guest_count >= 0),
  ADD CONSTRAINT hhm_space_reservations_version CHECK (version >= 0),
  ADD CONSTRAINT hhm_space_reservations_tenant_id_identity UNIQUE (tenant_id, id),
  ADD CONSTRAINT hhm_space_reservations_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_space_reservations_tenant_space_fkey
    FOREIGN KEY (tenant_id, location_id, space_id)
    REFERENCES public.hhm_bookable_spaces (tenant_id, location_id, id),
  ADD CONSTRAINT hhm_space_reservations_tenant_booker_fkey
    FOREIGN KEY (tenant_id, booked_by_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id),
  ADD CONSTRAINT hhm_space_reservations_tenant_organization_fkey
    FOREIGN KEY (tenant_id, organization_id)
    REFERENCES public.hhm_organizations (tenant_id, id),
  ADD CONSTRAINT hhm_space_reservations_no_active_overlap
    EXCLUDE USING gist (
      tenant_id WITH =,
      space_id WITH =,
      tstzrange(starts_at, ends_at, '[)') WITH &&
    )
    WHERE (status IN ('held', 'confirmed', 'checked_in'));

ALTER TABLE public.hhm_reservation_transitions
  ADD CONSTRAINT hhm_reservation_transitions_expected_version CHECK (expected_version >= 0),
  ADD CONSTRAINT hhm_reservation_transitions_reason_code CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  ADD CONSTRAINT hhm_reservation_transitions_tenant_reservation_fkey
    FOREIGN KEY (tenant_id, reservation_id)
    REFERENCES public.hhm_space_reservations (tenant_id, id),
  ADD CONSTRAINT hhm_reservation_transitions_tenant_actor_fkey
    FOREIGN KEY (tenant_id, actor_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_guest_passes
  ADD CONSTRAINT hhm_guest_passes_window CHECK (valid_from < valid_until),
  ADD CONSTRAINT hhm_guest_passes_version CHECK (version >= 0),
  ADD CONSTRAINT hhm_guest_passes_tenant_id_identity UNIQUE (tenant_id, id),
  ADD CONSTRAINT hhm_guest_passes_tenant_reservation_fkey
    FOREIGN KEY (tenant_id, reservation_id)
    REFERENCES public.hhm_space_reservations (tenant_id, id),
  ADD CONSTRAINT hhm_guest_passes_tenant_issuer_fkey
    FOREIGN KEY (tenant_id, issued_by_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_guest_pass_transitions
  ADD CONSTRAINT hhm_guest_pass_transitions_expected_version CHECK (expected_version >= 0),
  ADD CONSTRAINT hhm_guest_pass_transitions_reason_code CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  ADD CONSTRAINT hhm_guest_pass_transitions_tenant_pass_fkey
    FOREIGN KEY (tenant_id, guest_pass_id)
    REFERENCES public.hhm_guest_passes (tenant_id, id),
  ADD CONSTRAINT hhm_guest_pass_transitions_tenant_actor_fkey
    FOREIGN KEY (tenant_id, actor_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_visits
  ADD CONSTRAINT hhm_visits_exact_principal CHECK ((account_id IS NULL) <> (guest_pass_id IS NULL)),
  ADD CONSTRAINT hhm_visits_tenant_id_identity UNIQUE (tenant_id, id),
  ADD CONSTRAINT hhm_visits_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_visits_tenant_reservation_fkey
    FOREIGN KEY (tenant_id, reservation_id)
    REFERENCES public.hhm_space_reservations (tenant_id, id),
  ADD CONSTRAINT hhm_visits_tenant_pass_fkey
    FOREIGN KEY (tenant_id, guest_pass_id)
    REFERENCES public.hhm_guest_passes (tenant_id, id),
  ADD CONSTRAINT hhm_visits_tenant_account_fkey
    FOREIGN KEY (tenant_id, account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_visit_transitions
  ADD CONSTRAINT hhm_visit_transitions_expected_version CHECK (expected_version >= 0),
  ADD CONSTRAINT hhm_visit_transitions_reason_code CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  ADD CONSTRAINT hhm_visit_transitions_tenant_visit_fkey
    FOREIGN KEY (tenant_id, visit_id)
    REFERENCES public.hhm_visits (tenant_id, id),
  ADD CONSTRAINT hhm_visit_transitions_tenant_actor_fkey
    FOREIGN KEY (tenant_id, actor_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_access_grants
  ADD CONSTRAINT hhm_access_grants_window CHECK (valid_from < valid_until),
  ADD CONSTRAINT hhm_access_grants_exact_principal CHECK ((account_id IS NULL) <> (guest_pass_id IS NULL)),
  ADD CONSTRAINT hhm_access_grants_version CHECK (version >= 0),
  ADD CONSTRAINT hhm_access_grants_tenant_id_identity UNIQUE (tenant_id, id),
  ADD CONSTRAINT hhm_access_grants_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_access_grants_tenant_space_fkey
    FOREIGN KEY (tenant_id, location_id, space_id)
    REFERENCES public.hhm_bookable_spaces (tenant_id, location_id, id),
  ADD CONSTRAINT hhm_access_grants_tenant_account_fkey
    FOREIGN KEY (tenant_id, account_id)
    REFERENCES public.hhm_accounts (tenant_id, id),
  ADD CONSTRAINT hhm_access_grants_tenant_pass_fkey
    FOREIGN KEY (tenant_id, guest_pass_id)
    REFERENCES public.hhm_guest_passes (tenant_id, id),
  ADD CONSTRAINT hhm_access_grants_tenant_reservation_fkey
    FOREIGN KEY (tenant_id, reservation_id)
    REFERENCES public.hhm_space_reservations (tenant_id, id);

ALTER TABLE public.hhm_access_grant_transitions
  ADD CONSTRAINT hhm_access_grant_transitions_expected_version CHECK (expected_version >= 0),
  ADD CONSTRAINT hhm_access_grant_transitions_reason_code CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$'),
  ADD CONSTRAINT hhm_access_grant_transitions_tenant_grant_fkey
    FOREIGN KEY (tenant_id, access_grant_id)
    REFERENCES public.hhm_access_grants (tenant_id, id),
  ADD CONSTRAINT hhm_access_grant_transitions_tenant_actor_fkey
    FOREIGN KEY (tenant_id, actor_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_access_decisions
  ADD CONSTRAINT hhm_access_decisions_exact_principal CHECK ((account_id IS NULL) <> (guest_pass_id IS NULL)),
  ADD CONSTRAINT hhm_access_decisions_digest CHECK (evidence_digest_sha256 ~ '^[a-f0-9]{64}$'),
  ADD CONSTRAINT hhm_access_decisions_fail_closed CHECK (
    (outcome = 'allowed' AND reason = 'matching_active_grant')
    OR (outcome = 'denied' AND reason <> 'matching_active_grant')
  ),
  ADD CONSTRAINT hhm_access_decisions_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_access_decisions_tenant_space_fkey
    FOREIGN KEY (tenant_id, location_id, space_id)
    REFERENCES public.hhm_bookable_spaces (tenant_id, location_id, id),
  ADD CONSTRAINT hhm_access_decisions_tenant_account_fkey
    FOREIGN KEY (tenant_id, account_id)
    REFERENCES public.hhm_accounts (tenant_id, id),
  ADD CONSTRAINT hhm_access_decisions_tenant_pass_fkey
    FOREIGN KEY (tenant_id, guest_pass_id)
    REFERENCES public.hhm_guest_passes (tenant_id, id),
  ADD CONSTRAINT hhm_access_decisions_tenant_grant_fkey
    FOREIGN KEY (tenant_id, access_grant_id)
    REFERENCES public.hhm_access_grants (tenant_id, id);

ALTER TABLE public.hhm_network_credentials
  ADD CONSTRAINT hhm_network_credentials_window CHECK (valid_from < valid_until),
  ADD CONSTRAINT hhm_network_credentials_version CHECK (version >= 0),
  ADD CONSTRAINT hhm_network_credentials_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_network_credentials_tenant_account_fkey
    FOREIGN KEY (tenant_id, account_id)
    REFERENCES public.hhm_accounts (tenant_id, id),
  ADD CONSTRAINT hhm_network_credentials_tenant_reservation_fkey
    FOREIGN KEY (tenant_id, reservation_id)
    REFERENCES public.hhm_space_reservations (tenant_id, id);

ALTER TABLE public.hhm_maintenance_tickets
  ADD CONSTRAINT hhm_maintenance_tickets_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_maintenance_tickets_tenant_space_fkey
    FOREIGN KEY (tenant_id, space_id)
    REFERENCES public.hhm_bookable_spaces (tenant_id, id),
  ADD CONSTRAINT hhm_maintenance_tickets_tenant_reporter_fkey
    FOREIGN KEY (tenant_id, reported_by_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id),
  ADD CONSTRAINT hhm_maintenance_tickets_tenant_assignee_fkey
    FOREIGN KEY (tenant_id, assigned_to_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_housekeeping_tasks
  ADD CONSTRAINT hhm_housekeeping_tasks_window CHECK (scheduled_from < scheduled_until),
  ADD CONSTRAINT hhm_housekeeping_tasks_version CHECK (version >= 0),
  ADD CONSTRAINT hhm_housekeeping_tasks_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_housekeeping_tasks_tenant_space_fkey
    FOREIGN KEY (tenant_id, space_id)
    REFERENCES public.hhm_bookable_spaces (tenant_id, id),
  ADD CONSTRAINT hhm_housekeeping_tasks_tenant_reservation_fkey
    FOREIGN KEY (tenant_id, reservation_id)
    REFERENCES public.hhm_space_reservations (tenant_id, id),
  ADD CONSTRAINT hhm_housekeeping_tasks_tenant_assignee_fkey
    FOREIGN KEY (tenant_id, assigned_to_account_id)
    REFERENCES public.hhm_accounts (tenant_id, id);

ALTER TABLE public.hhm_security_observations
  ADD CONSTRAINT hhm_security_observations_tenant_location_fkey
    FOREIGN KEY (tenant_id, location_id)
    REFERENCES public.hhm_locations (tenant_id, id),
  ADD CONSTRAINT hhm_security_observations_tenant_space_fkey
    FOREIGN KEY (tenant_id, space_id)
    REFERENCES public.hhm_bookable_spaces (tenant_id, id),
  ADD CONSTRAINT hhm_security_observations_tenant_grant_fkey
    FOREIGN KEY (tenant_id, access_grant_id)
    REFERENCES public.hhm_access_grants (tenant_id, id),
  ADD CONSTRAINT hhm_security_observations_tenant_visit_fkey
    FOREIGN KEY (tenant_id, visit_id)
    REFERENCES public.hhm_visits (tenant_id, id);

CREATE FUNCTION public.hhm_current_tenant_id()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
  SELECT nullif(current_setting('hhm.tenant_id', true), '')
$function$;

CREATE FUNCTION public.hhm_assert_platform_tenant(requested_tenant text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF requested_tenant IS NULL
    OR requested_tenant = ''
    OR requested_tenant IS DISTINCT FROM public.hhm_current_tenant_id()
  THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'platform tenant scope denied';
  END IF;
END
$function$;

CREATE FUNCTION public.hhm_check_reservation_capacity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
DECLARE
  selected_capacity integer;
BEGIN
  SELECT capacity
  INTO selected_capacity
  FROM public.hhm_bookable_spaces
  WHERE tenant_id = NEW.tenant_id
    AND location_id = NEW.location_id
    AND id = NEW.space_id
    AND active
  FOR SHARE;

  IF selected_capacity IS NULL OR NEW.occupant_count + NEW.guest_count > selected_capacity THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'reservation exceeds active space capacity';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER hhm_space_reservations_capacity
BEFORE INSERT OR UPDATE OF tenant_id, location_id, space_id, occupant_count, guest_count
ON public.hhm_space_reservations
FOR EACH ROW EXECUTE FUNCTION public.hhm_check_reservation_capacity();

CREATE FUNCTION public.hhm_forbid_platform_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
BEGIN
  RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'platform ledger rows are append-only';
END
$function$;

CREATE TRIGGER hhm_reservation_transitions_append_only
BEFORE UPDATE OR DELETE ON public.hhm_reservation_transitions
FOR EACH ROW EXECUTE FUNCTION public.hhm_forbid_platform_ledger_mutation();
CREATE TRIGGER hhm_guest_pass_transitions_append_only
BEFORE UPDATE OR DELETE ON public.hhm_guest_pass_transitions
FOR EACH ROW EXECUTE FUNCTION public.hhm_forbid_platform_ledger_mutation();
CREATE TRIGGER hhm_visit_transitions_append_only
BEFORE UPDATE OR DELETE ON public.hhm_visit_transitions
FOR EACH ROW EXECUTE FUNCTION public.hhm_forbid_platform_ledger_mutation();
CREATE TRIGGER hhm_access_grant_transitions_append_only
BEFORE UPDATE OR DELETE ON public.hhm_access_grant_transitions
FOR EACH ROW EXECUTE FUNCTION public.hhm_forbid_platform_ledger_mutation();
CREATE TRIGGER hhm_access_decisions_append_only
BEFORE UPDATE OR DELETE ON public.hhm_access_decisions
FOR EACH ROW EXECUTE FUNCTION public.hhm_forbid_platform_ledger_mutation();

CREATE FUNCTION public.hhm_transition_reservation(
  p_tenant_id text,
  p_reservation_id uuid,
  p_kind reservation_transition_kind,
  p_expected_version bigint,
  p_actor_account_id uuid,
  p_idempotency_key text,
  p_reason_code text,
  p_transition_id uuid,
  p_occurred_at timestamptz
)
RETURNS public.hhm_space_reservations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  prior public.hhm_reservation_transitions%ROWTYPE;
  result public.hhm_space_reservations%ROWTYPE;
BEGIN
  PERFORM public.hhm_assert_platform_tenant(p_tenant_id);
  SELECT * INTO prior
  FROM public.hhm_reservation_transitions
  WHERE tenant_id = p_tenant_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF prior.id IS DISTINCT FROM p_transition_id
      OR prior.reservation_id IS DISTINCT FROM p_reservation_id
      OR prior.kind IS DISTINCT FROM p_kind
      OR prior.expected_version IS DISTINCT FROM p_expected_version
      OR prior.actor_account_id IS DISTINCT FROM p_actor_account_id
      OR prior.reason_code IS DISTINCT FROM p_reason_code
      OR prior.occurred_at IS DISTINCT FROM p_occurred_at
    THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'reservation idempotency key payload mismatch';
    END IF;
    SELECT * INTO STRICT result
    FROM public.hhm_space_reservations
    WHERE tenant_id = p_tenant_id AND id = p_reservation_id;
    RETURN result;
  END IF;

  UPDATE public.hhm_space_reservations
  SET status = CASE p_kind
      WHEN 'requested_to_held' THEN 'held'::public.reservation_status
      WHEN 'requested_to_confirmed' THEN 'confirmed'::public.reservation_status
      WHEN 'requested_to_cancelled' THEN 'cancelled'::public.reservation_status
      WHEN 'held_to_confirmed' THEN 'confirmed'::public.reservation_status
      WHEN 'held_to_cancelled' THEN 'cancelled'::public.reservation_status
      WHEN 'held_to_expired' THEN 'expired'::public.reservation_status
      WHEN 'confirmed_to_checked_in' THEN 'checked_in'::public.reservation_status
      WHEN 'confirmed_to_cancelled' THEN 'cancelled'::public.reservation_status
      WHEN 'confirmed_to_no_show' THEN 'no_show'::public.reservation_status
      WHEN 'checked_in_to_checked_out' THEN 'checked_out'::public.reservation_status
      WHEN 'checked_out_to_completed' THEN 'completed'::public.reservation_status
    END,
    version = version + 1,
    updated_at = p_occurred_at
  WHERE tenant_id = p_tenant_id
    AND id = p_reservation_id
    AND version = p_expected_version
    AND (
      (p_kind IN ('requested_to_held', 'requested_to_confirmed', 'requested_to_cancelled') AND status = 'requested')
      OR (p_kind IN ('held_to_confirmed', 'held_to_cancelled', 'held_to_expired') AND status = 'held')
      OR (p_kind IN ('confirmed_to_checked_in', 'confirmed_to_cancelled', 'confirmed_to_no_show') AND status = 'confirmed')
      OR (p_kind = 'checked_in_to_checked_out' AND status = 'checked_in')
      OR (p_kind = 'checked_out_to_completed' AND status = 'checked_out')
    )
  RETURNING * INTO result;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'reservation compare-and-swap rejected';
  END IF;

  INSERT INTO public.hhm_reservation_transitions (
    id, tenant_id, reservation_id, kind, expected_version,
    actor_account_id, idempotency_key, reason_code, occurred_at
  ) VALUES (
    p_transition_id, p_tenant_id, p_reservation_id, p_kind, p_expected_version,
    p_actor_account_id, p_idempotency_key, p_reason_code, p_occurred_at
  );
  RETURN result;
END
$function$;

CREATE FUNCTION public.hhm_transition_guest_pass(
  p_tenant_id text,
  p_guest_pass_id uuid,
  p_kind guest_pass_transition_kind,
  p_expected_version bigint,
  p_actor_account_id uuid,
  p_idempotency_key text,
  p_reason_code text,
  p_transition_id uuid,
  p_occurred_at timestamptz
)
RETURNS public.hhm_guest_passes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  prior public.hhm_guest_pass_transitions%ROWTYPE;
  result public.hhm_guest_passes%ROWTYPE;
BEGIN
  PERFORM public.hhm_assert_platform_tenant(p_tenant_id);
  SELECT * INTO prior FROM public.hhm_guest_pass_transitions
  WHERE tenant_id = p_tenant_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF prior.id IS DISTINCT FROM p_transition_id
      OR prior.guest_pass_id IS DISTINCT FROM p_guest_pass_id
      OR prior.kind IS DISTINCT FROM p_kind
      OR prior.expected_version IS DISTINCT FROM p_expected_version
      OR prior.actor_account_id IS DISTINCT FROM p_actor_account_id
      OR prior.reason_code IS DISTINCT FROM p_reason_code
      OR prior.occurred_at IS DISTINCT FROM p_occurred_at
    THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'guest pass idempotency key payload mismatch';
    END IF;
    SELECT * INTO STRICT result FROM public.hhm_guest_passes
    WHERE tenant_id = p_tenant_id AND id = p_guest_pass_id;
    RETURN result;
  END IF;

  UPDATE public.hhm_guest_passes
  SET status = CASE p_kind
      WHEN 'planned_to_issued' THEN 'issued'::public.guest_pass_status
      WHEN 'planned_to_cancelled' THEN 'cancelled'::public.guest_pass_status
      WHEN 'issued_to_checked_in' THEN 'checked_in'::public.guest_pass_status
      WHEN 'issued_to_revoked' THEN 'revoked'::public.guest_pass_status
      WHEN 'issued_to_expired' THEN 'expired'::public.guest_pass_status
      WHEN 'issued_to_cancelled' THEN 'cancelled'::public.guest_pass_status
      WHEN 'checked_in_to_checked_out' THEN 'checked_out'::public.guest_pass_status
      WHEN 'checked_in_to_revoked' THEN 'revoked'::public.guest_pass_status
    END,
    version = version + 1,
    updated_at = p_occurred_at
  WHERE tenant_id = p_tenant_id
    AND id = p_guest_pass_id
    AND version = p_expected_version
    AND (
      (p_kind IN ('planned_to_issued', 'planned_to_cancelled') AND status = 'planned')
      OR (p_kind IN ('issued_to_checked_in', 'issued_to_revoked', 'issued_to_expired', 'issued_to_cancelled') AND status = 'issued')
      OR (p_kind IN ('checked_in_to_checked_out', 'checked_in_to_revoked') AND status = 'checked_in')
    )
  RETURNING * INTO result;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'guest pass compare-and-swap rejected';
  END IF;

  INSERT INTO public.hhm_guest_pass_transitions (
    id, tenant_id, guest_pass_id, kind, expected_version,
    actor_account_id, idempotency_key, reason_code, occurred_at
  ) VALUES (
    p_transition_id, p_tenant_id, p_guest_pass_id, p_kind, p_expected_version,
    p_actor_account_id, p_idempotency_key, p_reason_code, p_occurred_at
  );
  RETURN result;
END
$function$;

CREATE FUNCTION public.hhm_transition_access_grant(
  p_tenant_id text,
  p_access_grant_id uuid,
  p_kind access_grant_transition_kind,
  p_expected_version bigint,
  p_actor_account_id uuid,
  p_idempotency_key text,
  p_reason_code text,
  p_transition_id uuid,
  p_occurred_at timestamptz
)
RETURNS public.hhm_access_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  prior public.hhm_access_grant_transitions%ROWTYPE;
  result public.hhm_access_grants%ROWTYPE;
BEGIN
  PERFORM public.hhm_assert_platform_tenant(p_tenant_id);
  SELECT * INTO prior FROM public.hhm_access_grant_transitions
  WHERE tenant_id = p_tenant_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF prior.id IS DISTINCT FROM p_transition_id
      OR prior.access_grant_id IS DISTINCT FROM p_access_grant_id
      OR prior.kind IS DISTINCT FROM p_kind
      OR prior.expected_version IS DISTINCT FROM p_expected_version
      OR prior.actor_account_id IS DISTINCT FROM p_actor_account_id
      OR prior.reason_code IS DISTINCT FROM p_reason_code
      OR prior.occurred_at IS DISTINCT FROM p_occurred_at
    THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'access grant idempotency key payload mismatch';
    END IF;
    SELECT * INTO STRICT result FROM public.hhm_access_grants
    WHERE tenant_id = p_tenant_id AND id = p_access_grant_id;
    RETURN result;
  END IF;

  UPDATE public.hhm_access_grants
  SET status = CASE p_kind
      WHEN 'pending_to_active' THEN 'active'::public.access_grant_status
      WHEN 'pending_to_revoked' THEN 'revoked'::public.access_grant_status
      WHEN 'pending_to_expired' THEN 'expired'::public.access_grant_status
      WHEN 'pending_to_denied' THEN 'denied'::public.access_grant_status
      WHEN 'active_to_revoked' THEN 'revoked'::public.access_grant_status
      WHEN 'active_to_expired' THEN 'expired'::public.access_grant_status
    END,
    version = version + 1,
    updated_at = p_occurred_at
  WHERE tenant_id = p_tenant_id
    AND id = p_access_grant_id
    AND version = p_expected_version
    AND (
      (p_kind IN ('pending_to_active', 'pending_to_revoked', 'pending_to_expired', 'pending_to_denied') AND status = 'pending')
      OR (p_kind IN ('active_to_revoked', 'active_to_expired') AND status = 'active')
    )
  RETURNING * INTO result;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'access grant compare-and-swap rejected';
  END IF;

  INSERT INTO public.hhm_access_grant_transitions (
    id, tenant_id, access_grant_id, kind, expected_version,
    actor_account_id, idempotency_key, reason_code, occurred_at
  ) VALUES (
    p_transition_id, p_tenant_id, p_access_grant_id, p_kind, p_expected_version,
    p_actor_account_id, p_idempotency_key, p_reason_code, p_occurred_at
  );
  RETURN result;
END
$function$;

CREATE FUNCTION public.hhm_transition_visit(
  p_tenant_id text,
  p_visit_id uuid,
  p_kind visit_transition_kind,
  p_expected_version bigint,
  p_actor_account_id uuid,
  p_idempotency_key text,
  p_reason_code text,
  p_transition_id uuid,
  p_occurred_at timestamptz
)
RETURNS public.hhm_visits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  prior public.hhm_visit_transitions%ROWTYPE;
  current_version bigint;
  current_status public.visit_status;
  result public.hhm_visits%ROWTYPE;
BEGIN
  PERFORM public.hhm_assert_platform_tenant(p_tenant_id);
  SELECT * INTO prior FROM public.hhm_visit_transitions
  WHERE tenant_id = p_tenant_id AND idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF prior.id IS DISTINCT FROM p_transition_id
      OR prior.visit_id IS DISTINCT FROM p_visit_id
      OR prior.kind IS DISTINCT FROM p_kind
      OR prior.expected_version IS DISTINCT FROM p_expected_version
      OR prior.actor_account_id IS DISTINCT FROM p_actor_account_id
      OR prior.reason_code IS DISTINCT FROM p_reason_code
      OR prior.occurred_at IS DISTINCT FROM p_occurred_at
    THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'visit idempotency key payload mismatch';
    END IF;
    SELECT * INTO STRICT result FROM public.hhm_visits
    WHERE tenant_id = p_tenant_id AND id = p_visit_id;
    RETURN result;
  END IF;

  SELECT status INTO current_status
  FROM public.hhm_visits
  WHERE tenant_id = p_tenant_id AND id = p_visit_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'visit compare-and-swap rejected';
  END IF;
  SELECT count(*)::bigint INTO current_version
  FROM public.hhm_visit_transitions
  WHERE tenant_id = p_tenant_id AND visit_id = p_visit_id;
  IF current_version <> p_expected_version OR NOT (
    (p_kind IN ('expected_to_checked_in', 'expected_to_denied', 'expected_to_cancelled') AND current_status = 'expected')
    OR (p_kind = 'checked_in_to_checked_out' AND current_status = 'checked_in')
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'visit compare-and-swap rejected';
  END IF;

  UPDATE public.hhm_visits
  SET status = CASE p_kind
      WHEN 'expected_to_checked_in' THEN 'checked_in'::public.visit_status
      WHEN 'expected_to_denied' THEN 'denied'::public.visit_status
      WHEN 'expected_to_cancelled' THEN 'cancelled'::public.visit_status
      WHEN 'checked_in_to_checked_out' THEN 'checked_out'::public.visit_status
    END,
    checked_in_at = CASE WHEN p_kind = 'expected_to_checked_in' THEN p_occurred_at ELSE checked_in_at END,
    checked_out_at = CASE WHEN p_kind = 'checked_in_to_checked_out' THEN p_occurred_at ELSE checked_out_at END,
    updated_at = p_occurred_at
  WHERE tenant_id = p_tenant_id AND id = p_visit_id
  RETURNING * INTO result;

  INSERT INTO public.hhm_visit_transitions (
    id, tenant_id, visit_id, kind, expected_version,
    actor_account_id, idempotency_key, reason_code, occurred_at
  ) VALUES (
    p_transition_id, p_tenant_id, p_visit_id, p_kind, p_expected_version,
    p_actor_account_id, p_idempotency_key, p_reason_code, p_occurred_at
  );
  RETURN result;
END
$function$;

CREATE FUNCTION public.hhm_record_access_decision(
  p_id uuid,
  p_tenant_id text,
  p_location_id uuid,
  p_space_id uuid,
  p_account_id uuid,
  p_guest_pass_id uuid,
  p_access_grant_id uuid,
  p_outcome access_decision_outcome,
  p_reason access_decision_reason,
  p_evidence_digest_sha256 text,
  p_policy_version text,
  p_request_id text,
  p_occurred_at timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  prior public.hhm_access_decisions%ROWTYPE;
BEGIN
  PERFORM public.hhm_assert_platform_tenant(p_tenant_id);
  SELECT * INTO prior FROM public.hhm_access_decisions
  WHERE tenant_id = p_tenant_id AND request_id = p_request_id;
  IF FOUND THEN
    IF prior.id IS DISTINCT FROM p_id
      OR prior.location_id IS DISTINCT FROM p_location_id
      OR prior.space_id IS DISTINCT FROM p_space_id
      OR prior.account_id IS DISTINCT FROM p_account_id
      OR prior.guest_pass_id IS DISTINCT FROM p_guest_pass_id
      OR prior.access_grant_id IS DISTINCT FROM p_access_grant_id
      OR prior.outcome IS DISTINCT FROM p_outcome
      OR prior.reason IS DISTINCT FROM p_reason
      OR prior.evidence_digest_sha256 IS DISTINCT FROM p_evidence_digest_sha256
      OR prior.policy_version IS DISTINCT FROM p_policy_version
      OR prior.occurred_at IS DISTINCT FROM p_occurred_at
    THEN
      RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'access request id payload mismatch';
    END IF;
    RETURN prior.id;
  END IF;

  IF p_outcome = 'allowed' AND NOT EXISTS (
    SELECT 1
    FROM public.hhm_access_grants
    WHERE id = p_access_grant_id
      AND tenant_id = p_tenant_id
      AND location_id = p_location_id
      AND space_id = p_space_id
      AND account_id IS NOT DISTINCT FROM p_account_id
      AND guest_pass_id IS NOT DISTINCT FROM p_guest_pass_id
      AND status = 'active'
      AND valid_from <= p_occurred_at
      AND p_occurred_at < valid_until
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'allowed access requires an exact active grant';
  END IF;

  INSERT INTO public.hhm_access_decisions (
    id, tenant_id, location_id, space_id, account_id, guest_pass_id,
    access_grant_id, outcome, reason, evidence_digest_sha256,
    policy_version, request_id, occurred_at
  ) VALUES (
    p_id, p_tenant_id, p_location_id, p_space_id, p_account_id, p_guest_pass_id,
    p_access_grant_id, p_outcome, p_reason, p_evidence_digest_sha256,
    p_policy_version, p_request_id, p_occurred_at
  );
  RETURN p_id;
END
$function$;

DO $rls$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'hhm_access_decisions',
    'hhm_access_grants',
    'hhm_access_grant_transitions',
    'hhm_accounts',
    'hhm_guest_passes',
    'hhm_guest_pass_transitions',
    'hhm_housekeeping_tasks',
    'hhm_locations',
    'hhm_maintenance_tickets',
    'hhm_network_credentials',
    'hhm_organizations',
    'hhm_space_reservations',
    'hhm_reservation_transitions',
    'hhm_security_observations',
    'hhm_bookable_spaces',
    'hhm_visits',
    'hhm_visit_transitions'
  ]
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format(
      'CREATE POLICY hhm_platform_tenant_scope ON public.%I TO hhm_platform_reader, hhm_platform_writer USING (tenant_id = public.hhm_current_tenant_id()) WITH CHECK (tenant_id = public.hhm_current_tenant_id())',
      table_name
    );
  END LOOP;
END
$rls$;

REVOKE ALL ON FUNCTION public.hhm_current_tenant_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_assert_platform_tenant(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_check_reservation_capacity() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_forbid_platform_ledger_mutation() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_transition_reservation(text, uuid, reservation_transition_kind, bigint, uuid, text, text, uuid, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_transition_guest_pass(text, uuid, guest_pass_transition_kind, bigint, uuid, text, text, uuid, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_transition_access_grant(text, uuid, access_grant_transition_kind, bigint, uuid, text, text, uuid, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_transition_visit(text, uuid, visit_transition_kind, bigint, uuid, text, text, uuid, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hhm_record_access_decision(uuid, text, uuid, uuid, uuid, uuid, uuid, access_decision_outcome, access_decision_reason, text, text, text, timestamptz) FROM PUBLIC;

REVOKE ALL ON
  public.hhm_access_decisions,
  public.hhm_access_grants,
  public.hhm_access_grant_transitions,
  public.hhm_accounts,
  public.hhm_guest_passes,
  public.hhm_guest_pass_transitions,
  public.hhm_housekeeping_tasks,
  public.hhm_locations,
  public.hhm_maintenance_tickets,
  public.hhm_network_credentials,
  public.hhm_organizations,
  public.hhm_space_reservations,
  public.hhm_reservation_transitions,
  public.hhm_security_observations,
  public.hhm_bookable_spaces,
  public.hhm_visits,
  public.hhm_visit_transitions
FROM hhm_platform_reader, hhm_platform_writer;
GRANT USAGE ON SCHEMA public TO hhm_platform_reader, hhm_platform_writer;
GRANT EXECUTE ON FUNCTION public.hhm_current_tenant_id() TO hhm_platform_reader, hhm_platform_writer;
GRANT SELECT ON
  public.hhm_access_decisions,
  public.hhm_access_grants,
  public.hhm_access_grant_transitions,
  public.hhm_accounts,
  public.hhm_guest_passes,
  public.hhm_guest_pass_transitions,
  public.hhm_housekeeping_tasks,
  public.hhm_locations,
  public.hhm_maintenance_tickets,
  public.hhm_network_credentials,
  public.hhm_organizations,
  public.hhm_space_reservations,
  public.hhm_reservation_transitions,
  public.hhm_security_observations,
  public.hhm_bookable_spaces,
  public.hhm_visits,
  public.hhm_visit_transitions
TO hhm_platform_reader, hhm_platform_writer;

GRANT INSERT, UPDATE ON
  public.hhm_organizations,
  public.hhm_accounts,
  public.hhm_locations,
  public.hhm_bookable_spaces,
  public.hhm_network_credentials,
  public.hhm_maintenance_tickets,
  public.hhm_housekeeping_tasks,
  public.hhm_security_observations
TO hhm_platform_writer;
GRANT INSERT ON
  public.hhm_space_reservations,
  public.hhm_guest_passes,
  public.hhm_access_grants,
  public.hhm_visits
TO hhm_platform_writer;

GRANT USAGE ON TYPE
  access_decision_outcome,
  access_decision_reason,
  access_grant_status,
  access_grant_transition_kind,
  account_kind,
  account_status,
  guest_pass_status,
  guest_pass_transition_kind,
  housekeeping_status,
  maintenance_priority,
  maintenance_status,
  network_credential_status,
  organization_status,
  reservation_status,
  reservation_transition_kind,
  security_disposition,
  security_observation_kind,
  space_kind,
  visit_status,
  visit_transition_kind
TO hhm_platform_reader, hhm_platform_writer;

GRANT EXECUTE ON FUNCTION public.hhm_transition_reservation(text, uuid, reservation_transition_kind, bigint, uuid, text, text, uuid, timestamptz) TO hhm_platform_writer;
GRANT EXECUTE ON FUNCTION public.hhm_transition_guest_pass(text, uuid, guest_pass_transition_kind, bigint, uuid, text, text, uuid, timestamptz) TO hhm_platform_writer;
GRANT EXECUTE ON FUNCTION public.hhm_transition_access_grant(text, uuid, access_grant_transition_kind, bigint, uuid, text, text, uuid, timestamptz) TO hhm_platform_writer;
GRANT EXECUTE ON FUNCTION public.hhm_transition_visit(text, uuid, visit_transition_kind, bigint, uuid, text, text, uuid, timestamptz) TO hhm_platform_writer;
GRANT EXECUTE ON FUNCTION public.hhm_record_access_decision(uuid, text, uuid, uuid, uuid, uuid, uuid, access_decision_outcome, access_decision_reason, text, text, text, timestamptz) TO hhm_platform_writer;

COMMENT ON TABLE public.hhm_space_reservations IS
  'Normalized platform reservations; intentionally distinct from legacy public.hhm_reservations.';
COMMENT ON FUNCTION public.hhm_transition_visit(text, uuid, visit_transition_kind, bigint, uuid, text, text, uuid, timestamptz) IS
  'CAS version is the append-only transition count because the immutable v1 Visit contract has no version column.';

COMMIT;
