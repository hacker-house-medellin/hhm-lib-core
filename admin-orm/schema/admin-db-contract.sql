-- Declarative authority for the isolated HHaus admin database.
--
-- Apply only with the dedicated migration owner. API and worker processes use
-- separate least-privilege runtime roles and never execute this DDL.

CREATE TABLE admin_principals (
    shared_auth_subject text PRIMARY KEY,
    status text NOT NULL CHECK (status IN ('active', 'suspended', 'revoked')),
    permissions text[] NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (cardinality(permissions) <= 64)
);

CREATE TABLE admin_action_requests (
    operation_id uuid PRIMARY KEY,
    idempotency_key text NOT NULL UNIQUE,
    actor_subject text NOT NULL REFERENCES admin_principals(shared_auth_subject),
    actor_session_id text NOT NULL,
    resource text NOT NULL,
    action text NOT NULL,
    reason text NOT NULL,
    status text NOT NULL DEFAULT 'accepted'
        CHECK (status IN ('accepted', 'running', 'succeeded', 'failed', 'rejected')),
    requested_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    CHECK (length(idempotency_key) BETWEEN 8 AND 128),
    CHECK (length(reason) BETWEEN 8 AND 500)
);

CREATE TABLE admin_action_outbox (
    operation_id uuid PRIMARY KEY REFERENCES admin_action_requests(operation_id),
    event_kind text NOT NULL CHECK (event_kind = 'admin.action.requested'),
    delivery_status text NOT NULL DEFAULT 'pending'
        CHECK (delivery_status IN ('pending', 'delivering', 'delivered', 'failed', 'dead_letter')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 100),
    available_at timestamptz NOT NULL DEFAULT now(),
    lease_token uuid,
    lease_expires_at timestamptz,
    claimed_by text,
    delivered_at timestamptz,
    last_error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (
        (delivery_status = 'delivering'
          AND lease_token IS NOT NULL
          AND lease_expires_at IS NOT NULL
          AND claimed_by IS NOT NULL)
        OR
        (delivery_status <> 'delivering'
          AND lease_token IS NULL
          AND lease_expires_at IS NULL
          AND claimed_by IS NULL)
    ),
    CHECK (last_error_code IS NULL OR last_error_code ~ '^[a-z][a-z0-9_.:-]{1,63}$')
);

CREATE INDEX admin_action_outbox_pending_idx
    ON admin_action_outbox (available_at, operation_id)
    WHERE delivery_status IN ('pending', 'failed');

CREATE INDEX admin_action_outbox_expired_lease_idx
    ON admin_action_outbox (lease_expires_at, operation_id)
    WHERE delivery_status = 'delivering';

-- Runtime roles are separate from the migration owner. The API runtime receives
-- only SELECT on admin_principals and SELECT/INSERT/UPDATE on action requests and
-- the outbox. The worker receives the same table privileges under a distinct
-- credential. Neither role receives CREATE, CREATEROLE, CREATEDB, REPLICATION,
-- BYPASSRLS, or any customer service CONNECT grant.
