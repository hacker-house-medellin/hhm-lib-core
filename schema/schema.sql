-- Declarative HHaus intake schema.
--
-- This file is the authority for PostgreSQL, Supabase, Diesel schema output,
-- and generated SeaORM entities. It is converged with declarative-migrations;
-- application processes never run DDL.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE FUNCTION hhm_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at := transaction_timestamp();
  RETURN NEW;
END;
$$;

CREATE TABLE hhm_pre_interests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key varchar(128) NOT NULL UNIQUE,
  payload_sha256 char(64) NOT NULL,
  applicant_subject varchar(255),
  email varchar(320) NOT NULL,
  linkedin_url varchar(500) NOT NULL,
  entrepreneurship_idea varchar(4000) NOT NULL,
  stay_preference varchar(32) NOT NULL,
  privacy_notice_version varchar(64) NOT NULL,
  source_host varchar(255) NOT NULL,
  mirror_status varchar(32) NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_pre_interests_sha256 CHECK (payload_sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT hhm_pre_interests_email CHECK (email = btrim(email) AND position('@' IN email) > 1),
  CONSTRAINT hhm_pre_interests_linkedin CHECK (linkedin_url ~ '^https://(www\\.)?linkedin\\.(com|cn)/in/'),
  CONSTRAINT hhm_pre_interests_idea CHECK (char_length(entrepreneurship_idea) BETWEEN 40 AND 4000),
  CONSTRAINT hhm_pre_interests_stay CHECK (
    stay_preference = 'three_months' OR stay_preference = 'six_months'
  ),
  CONSTRAINT hhm_pre_interests_mirror CHECK (
    mirror_status = 'pending'
    OR mirror_status = 'mirrored'
    OR mirror_status = 'retryable_failure'
    OR mirror_status = 'terminal_failure'
  )
);

CREATE INDEX hhm_pre_interests_created_idx ON hhm_pre_interests (created_at DESC);
CREATE INDEX hhm_pre_interests_subject_idx ON hhm_pre_interests (applicant_subject) WHERE applicant_subject IS NOT NULL;
CREATE INDEX hhm_pre_interests_email_idx ON hhm_pre_interests (lower(email));

CREATE TRIGGER hhm_pre_interests_touch_updated_at
BEFORE UPDATE ON hhm_pre_interests
FOR EACH ROW EXECUTE FUNCTION hhm_touch_updated_at();

CREATE TABLE hhm_intake_uploads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key varchar(128) NOT NULL UNIQUE,
  payload_sha256 char(64) NOT NULL,
  applicant_subject varchar(255),
  kind varchar(32) NOT NULL,
  object_key varchar(1024) NOT NULL UNIQUE,
  content_sha256 char(64) NOT NULL,
  content_type varchar(128) NOT NULL,
  size_bytes bigint NOT NULL,
  status varchar(32) NOT NULL DEFAULT 'pending',
  expires_at timestamptz NOT NULL,
  uploaded_at timestamptz,
  verified_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_intake_uploads_payload_sha256 CHECK (payload_sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT hhm_intake_uploads_content_sha256 CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT hhm_intake_uploads_kind CHECK (kind = 'resume' OR kind = 'photo_id'),
  CONSTRAINT hhm_intake_uploads_type CHECK (
    content_type = 'application/pdf'
    OR content_type = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    OR content_type = 'image/jpeg'
    OR content_type = 'image/png'
    OR content_type = 'image/heic'
  ),
  CONSTRAINT hhm_intake_uploads_size CHECK (size_bytes BETWEEN 1 AND 10485760),
  CONSTRAINT hhm_intake_uploads_status CHECK (
    status = 'pending'
    OR status = 'uploaded'
    OR status = 'verified'
    OR status = 'quarantined'
    OR status = 'expired'
    OR status = 'deleted'
  ),
  CONSTRAINT hhm_intake_uploads_lifecycle CHECK (
    (status = 'pending' AND uploaded_at IS NULL AND verified_at IS NULL AND deleted_at IS NULL)
    OR (status = 'uploaded' AND uploaded_at IS NOT NULL AND verified_at IS NULL AND deleted_at IS NULL)
    OR ((status = 'verified' OR status = 'quarantined') AND uploaded_at IS NOT NULL AND verified_at IS NOT NULL AND deleted_at IS NULL)
    OR ((status = 'expired' OR status = 'deleted') AND deleted_at IS NOT NULL)
  )
);

CREATE INDEX hhm_intake_uploads_expiry_idx ON hhm_intake_uploads (expires_at) WHERE deleted_at IS NULL;
CREATE INDEX hhm_intake_uploads_subject_idx ON hhm_intake_uploads (applicant_subject) WHERE applicant_subject IS NOT NULL;

CREATE TRIGGER hhm_intake_uploads_touch_updated_at
BEFORE UPDATE ON hhm_intake_uploads
FOR EACH ROW EXECUTE FUNCTION hhm_touch_updated_at();

CREATE TABLE hhm_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key varchar(128) NOT NULL UNIQUE,
  payload_sha256 char(64) NOT NULL,
  pre_interest_id uuid REFERENCES hhm_pre_interests(id) ON DELETE SET NULL,
  applicant_subject varchar(255),
  email varchar(320) NOT NULL,
  linkedin_url varchar(500) NOT NULL,
  legal_name varchar(200) NOT NULL,
  date_of_birth date NOT NULL,
  nationality varchar(120) NOT NULL,
  phone varchar(32) NOT NULL,
  current_city varchar(160) NOT NULL,
  github_url varchar(500),
  portfolio_url varchar(500),
  entrepreneurship_idea varchar(8000) NOT NULL,
  project_stage varchar(64) NOT NULL,
  stay_preference varchar(32) NOT NULL,
  preferred_start_month date NOT NULL,
  community_contribution varchar(4000) NOT NULL,
  accessibility_or_accommodation_notes varchar(4000),
  resume_upload_id uuid NOT NULL REFERENCES hhm_intake_uploads(id) ON DELETE RESTRICT,
  photo_id_upload_id uuid NOT NULL REFERENCES hhm_intake_uploads(id) ON DELETE RESTRICT,
  age_and_identity_attestation boolean NOT NULL,
  privacy_notice_version varchar(64) NOT NULL,
  status varchar(32) NOT NULL DEFAULT 'submitted',
  mirror_status varchar(32) NOT NULL DEFAULT 'pending',
  submitted_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_applications_sha256 CHECK (payload_sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT hhm_applications_email CHECK (email = btrim(email) AND position('@' IN email) > 1),
  CONSTRAINT hhm_applications_linkedin CHECK (linkedin_url ~ '^https://(www\\.)?linkedin\\.(com|cn)/in/'),
  CONSTRAINT hhm_applications_adult CHECK (date_of_birth <= (current_date - INTERVAL '18 years')::date AND date_of_birth >= DATE '1900-01-01'),
  CONSTRAINT hhm_applications_github CHECK (github_url IS NULL OR github_url ~ '^https://github\\.com/'),
  CONSTRAINT hhm_applications_portfolio CHECK (portfolio_url IS NULL OR portfolio_url ~ '^https://'),
  CONSTRAINT hhm_applications_idea CHECK (char_length(entrepreneurship_idea) BETWEEN 80 AND 8000),
  CONSTRAINT hhm_applications_project_stage CHECK (
    project_stage = 'idea'
    OR project_stage = 'prototype'
    OR project_stage = 'early_revenue'
    OR project_stage = 'growing'
    OR project_stage = 'nonprofit_or_open_source'
  ),
  CONSTRAINT hhm_applications_stay CHECK (
    stay_preference = 'three_months' OR stay_preference = 'six_months'
  ),
  CONSTRAINT hhm_applications_attestation CHECK (age_and_identity_attestation),
  CONSTRAINT hhm_applications_uploads_distinct CHECK (resume_upload_id <> photo_id_upload_id),
  CONSTRAINT hhm_applications_status CHECK (
    status = 'submitted'
    OR status = 'under_review'
    OR status = 'needs_information'
    OR status = 'interview'
    OR status = 'accepted'
    OR status = 'waitlisted'
    OR status = 'declined'
    OR status = 'withdrawn'
  ),
  CONSTRAINT hhm_applications_mirror CHECK (
    mirror_status = 'pending'
    OR mirror_status = 'mirrored'
    OR mirror_status = 'retryable_failure'
    OR mirror_status = 'terminal_failure'
  )
);

CREATE INDEX hhm_applications_status_idx ON hhm_applications (status, submitted_at DESC);
CREATE INDEX hhm_applications_subject_idx ON hhm_applications (applicant_subject) WHERE applicant_subject IS NOT NULL;
CREATE INDEX hhm_applications_email_idx ON hhm_applications (lower(email));
CREATE INDEX hhm_applications_pre_interest_idx ON hhm_applications (pre_interest_id) WHERE pre_interest_id IS NOT NULL;
CREATE INDEX hhm_applications_resume_upload_idx ON hhm_applications (resume_upload_id);
CREATE INDEX hhm_applications_photo_id_upload_idx ON hhm_applications (photo_id_upload_id);

CREATE TRIGGER hhm_applications_touch_updated_at
BEFORE UPDATE ON hhm_applications
FOR EACH ROW EXECUTE FUNCTION hhm_touch_updated_at();

CREATE TABLE hhm_referrals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key varchar(128) NOT NULL UNIQUE,
  payload_sha256 char(64) NOT NULL,
  referrer_subject varchar(255) NOT NULL,
  referee_name varchar(200) NOT NULL,
  referee_email varchar(320) NOT NULL,
  referee_linkedin_url varchar(500) NOT NULL,
  relationship varchar(120) NOT NULL,
  rationale varchar(4000) NOT NULL,
  stay_preference varchar(32),
  nominee_consent_confirmed boolean NOT NULL,
  status varchar(32) NOT NULL DEFAULT 'submitted',
  mirror_status varchar(32) NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_referrals_sha256 CHECK (payload_sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT hhm_referrals_email CHECK (referee_email = btrim(referee_email) AND position('@' IN referee_email) > 1),
  CONSTRAINT hhm_referrals_linkedin CHECK (referee_linkedin_url ~ '^https://(www\\.)?linkedin\\.(com|cn)/in/'),
  CONSTRAINT hhm_referrals_rationale CHECK (char_length(rationale) BETWEEN 40 AND 4000),
  CONSTRAINT hhm_referrals_stay CHECK (
    stay_preference IS NULL
    OR stay_preference = 'three_months'
    OR stay_preference = 'six_months'
  ),
  CONSTRAINT hhm_referrals_consent CHECK (nominee_consent_confirmed),
  CONSTRAINT hhm_referrals_status CHECK (
    status = 'submitted'
    OR status = 'invited'
    OR status = 'applied'
    OR status = 'accepted'
    OR status = 'declined'
  ),
  CONSTRAINT hhm_referrals_mirror CHECK (
    mirror_status = 'pending'
    OR mirror_status = 'mirrored'
    OR mirror_status = 'retryable_failure'
    OR mirror_status = 'terminal_failure'
  )
);

CREATE INDEX hhm_referrals_referrer_idx ON hhm_referrals (referrer_subject, created_at DESC);
CREATE INDEX hhm_referrals_email_idx ON hhm_referrals (lower(referee_email));

CREATE TRIGGER hhm_referrals_touch_updated_at
BEFORE UPDATE ON hhm_referrals
FOR EACH ROW EXECUTE FUNCTION hhm_touch_updated_at();

CREATE TABLE hhm_submission_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  submission_kind varchar(32) NOT NULL,
  submission_id uuid NOT NULL,
  payload_sha256 char(64) NOT NULL,
  mirror_status varchar(32) NOT NULL DEFAULT 'pending',
  attempts integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  last_error_code varchar(64),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_submission_outbox_identity UNIQUE (submission_kind, submission_id),
  CONSTRAINT hhm_submission_outbox_kind CHECK (
    submission_kind = 'pre_interest'
    OR submission_kind = 'application'
    OR submission_kind = 'referral'
  ),
  CONSTRAINT hhm_submission_outbox_sha256 CHECK (payload_sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT hhm_submission_outbox_mirror CHECK (
    mirror_status = 'pending'
    OR mirror_status = 'mirrored'
    OR mirror_status = 'retryable_failure'
    OR mirror_status = 'terminal_failure'
  ),
  CONSTRAINT hhm_submission_outbox_attempts CHECK (attempts BETWEEN 0 AND 100)
);

CREATE INDEX hhm_submission_outbox_retry_idx ON hhm_submission_outbox (next_attempt_at, created_at)
WHERE mirror_status = 'pending' OR mirror_status = 'retryable_failure';

CREATE TRIGGER hhm_submission_outbox_touch_updated_at
BEFORE UPDATE ON hhm_submission_outbox
FOR EACH ROW EXECUTE FUNCTION hhm_touch_updated_at();

CREATE TABLE hhm_user_points_accounts (
  subject varchar(255) PRIMARY KEY,
  balance bigint NOT NULL DEFAULT 0,
  lifetime_earned bigint NOT NULL DEFAULT 0,
  lifetime_redeemed bigint NOT NULL DEFAULT 0,
  version bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_user_points_accounts_balance CHECK (balance >= 0),
  CONSTRAINT hhm_user_points_accounts_totals CHECK (lifetime_earned >= 0 AND lifetime_redeemed >= 0),
  CONSTRAINT hhm_user_points_accounts_version CHECK (version >= 0)
);

CREATE TABLE hhm_user_points_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key varchar(128) NOT NULL UNIQUE,
  subject varchar(255) NOT NULL,
  delta bigint NOT NULL,
  reason_code varchar(64) NOT NULL,
  source_submission_id uuid,
  actor_subject varchar(255) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CONSTRAINT hhm_user_points_ledger_delta CHECK (delta <> 0),
  CONSTRAINT hhm_user_points_ledger_reason CHECK (reason_code ~ '^[a-z][a-z0-9_]{1,63}$')
);

CREATE INDEX hhm_user_points_ledger_subject_idx ON hhm_user_points_ledger (subject, created_at DESC);
CREATE INDEX hhm_user_points_ledger_source_idx ON hhm_user_points_ledger (source_submission_id) WHERE source_submission_id IS NOT NULL;

CREATE FUNCTION hhm_apply_points_ledger_entry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  updated_rows integer;
BEGIN
  INSERT INTO hhm_user_points_accounts (
    subject, balance, lifetime_earned, lifetime_redeemed, version
  ) VALUES (
    NEW.subject,
    NEW.delta,
    GREATEST(NEW.delta, 0),
    GREATEST(-NEW.delta, 0),
    1
  )
  ON CONFLICT (subject) DO UPDATE SET
    balance = hhm_user_points_accounts.balance + EXCLUDED.balance,
    lifetime_earned = hhm_user_points_accounts.lifetime_earned + EXCLUDED.lifetime_earned,
    lifetime_redeemed = hhm_user_points_accounts.lifetime_redeemed + EXCLUDED.lifetime_redeemed,
    version = hhm_user_points_accounts.version + 1,
    updated_at = transaction_timestamp()
  WHERE hhm_user_points_accounts.balance + EXCLUDED.balance >= 0;

  GET DIAGNOSTICS updated_rows = ROW_COUNT;
  IF updated_rows <> 1 THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'user points balance cannot become negative';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER hhm_user_points_ledger_apply
AFTER INSERT ON hhm_user_points_ledger
FOR EACH ROW EXECUTE FUNCTION hhm_apply_points_ledger_entry();

CREATE FUNCTION hhm_forbid_points_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'user points ledger entries are immutable';
END;
$$;

CREATE TRIGGER hhm_user_points_ledger_immutable
BEFORE UPDATE OR DELETE ON hhm_user_points_ledger
FOR EACH ROW EXECUTE FUNCTION hhm_forbid_points_ledger_mutation();

ALTER TABLE hhm_pre_interests ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_pre_interests FORCE ROW LEVEL SECURITY;
ALTER TABLE hhm_intake_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_intake_uploads FORCE ROW LEVEL SECURITY;
ALTER TABLE hhm_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_applications FORCE ROW LEVEL SECURITY;
ALTER TABLE hhm_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_referrals FORCE ROW LEVEL SECURITY;
ALTER TABLE hhm_submission_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_submission_outbox FORCE ROW LEVEL SECURITY;
ALTER TABLE hhm_user_points_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_user_points_accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE hhm_user_points_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE hhm_user_points_ledger FORCE ROW LEVEL SECURITY;

CREATE POLICY hhm_pre_interests_service_access ON hhm_pre_interests
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
CREATE POLICY hhm_intake_uploads_service_access ON hhm_intake_uploads
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
CREATE POLICY hhm_applications_service_access ON hhm_applications
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
CREATE POLICY hhm_referrals_service_access ON hhm_referrals
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
CREATE POLICY hhm_submission_outbox_service_access ON hhm_submission_outbox
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
CREATE POLICY hhm_user_points_accounts_service_access ON hhm_user_points_accounts
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
CREATE POLICY hhm_user_points_ledger_service_access ON hhm_user_points_ledger
  FOR ALL USING (current_user IN ('postgres', 'service_role', 'hhm_app_service'))
  WITH CHECK (current_user IN ('postgres', 'service_role', 'hhm_app_service'));
