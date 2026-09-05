//! Product-owned, named ORM operations for the isolated admin database.
//!
//! Admin services depend on this surface from their product's `*-lib-core`
//! repository. The contexts keep the `SeaORM` connection private so callers
//! cannot bypass the reviewed operations with ad-hoc SQL.

use std::time::Duration;

use sea_orm::{
    ConnectOptions, ConnectionTrait, Database, DatabaseBackend, DatabaseConnection,
    DatabaseTransaction, Statement, TransactionTrait, TryGetable,
};
use url::Url;
use uuid::Uuid;

const MAX_CONNECTIONS: u32 = 8;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const ACQUIRE_TIMEOUT: Duration = Duration::from_secs(3);
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_RETRYABLE_FAILURES: i32 = 10;
const MAX_LEASE_ATTEMPTS: i32 = 100;

/// Secret-bearing connection input plus the reviewed, non-secret RDS identity.
///
/// This type intentionally does not implement `Debug`: a database URL must
/// never be emitted by logs, traces, panic reports, or test snapshots.
#[derive(Clone, Copy)]
pub struct AdminDatabaseConfig<'a> {
    pub database_url: &'a str,
    pub expected_host: &'a str,
    pub expected_database: &'a str,
    pub expected_role: &'a str,
}

impl AdminDatabaseConfig<'_> {
    fn connect_options(&self) -> Result<ConnectOptions, AdminOrmError> {
        self.validate()?;
        let mut options = ConnectOptions::new(self.database_url.to_owned());
        options
            .max_connections(MAX_CONNECTIONS)
            .min_connections(1)
            .connect_timeout(CONNECT_TIMEOUT)
            .acquire_timeout(ACQUIRE_TIMEOUT)
            .idle_timeout(IDLE_TIMEOUT)
            .sqlx_logging(false);
        Ok(options)
    }

    fn validate(&self) -> Result<(), AdminOrmError> {
        let url =
            Url::parse(self.database_url).map_err(|_| AdminOrmError::InvalidDatabaseTarget)?;
        if !matches!(url.scheme(), "postgres" | "postgresql")
            || url.host_str() != Some(self.expected_host)
            || url.username() != self.expected_role
            || url.fragment().is_some()
            || !valid_identifier(self.expected_database)
            || !valid_identifier(self.expected_role)
        {
            return Err(AdminOrmError::InvalidDatabaseTarget);
        }
        let database = url
            .path()
            .strip_prefix('/')
            .filter(|value| !value.is_empty() && !value.contains('/'))
            .ok_or(AdminOrmError::InvalidDatabaseTarget)?;
        if database != self.expected_database {
            return Err(AdminOrmError::InvalidDatabaseTarget);
        }
        let ssl_modes = url
            .query_pairs()
            .filter(|(name, _)| name == "sslmode")
            .map(|(_, value)| value)
            .collect::<Vec<_>>();
        if ssl_modes.len() != 1 || ssl_modes[0] != "verify-full" {
            return Err(AdminOrmError::InvalidDatabaseTarget);
        }
        Ok(())
    }
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdminPermission {
    Read,
    Write,
}

impl AdminPermission {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "admin:read",
            Self::Write => "admin:write",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct AdminDashboardStats {
    pub active_admins: i64,
    pub pending_actions: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdminAction<'a> {
    pub idempotency_key: &'a str,
    pub actor_subject: &'a str,
    pub actor_session_id: &'a str,
    pub resource: &'a str,
    pub action: &'a str,
    pub reason: &'a str,
}

/// One fenced admin action leased to a single worker execution.
///
/// This type intentionally does not implement `Debug`: it contains the raw
/// actor subject needed for the product ledger and must not enter logs.
pub struct ClaimedAdminAction {
    operation_id: Uuid,
    lease_token: Uuid,
    actor_subject: String,
    resource: String,
    action: String,
    attempts: i32,
}

impl ClaimedAdminAction {
    #[must_use]
    pub const fn operation_id(&self) -> Uuid {
        self.operation_id
    }

    #[must_use]
    pub const fn lease_token(&self) -> Uuid {
        self.lease_token
    }

    #[must_use]
    pub fn actor_subject(&self) -> &str {
        &self.actor_subject
    }

    #[must_use]
    pub fn resource(&self) -> &str {
        &self.resource
    }

    #[must_use]
    pub fn action(&self) -> &str {
        &self.action
    }

    #[must_use]
    pub const fn attempts(&self) -> i32 {
        self.attempts
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdminActionOutcome<'a> {
    Succeeded,
    Rejected { error_code: &'a str },
    RetryableFailure { error_code: &'a str },
}

#[derive(Debug, thiserror::Error)]
pub enum AdminOrmError {
    #[error("admin database operation failed")]
    Database(#[source] sea_orm::DbErr),
    #[error("admin database returned an unexpected value")]
    Decode,
    #[error("admin database returned an invalid operation identifier")]
    InvalidOperationId,
    #[error("admin database target does not match the reviewed RDS identity")]
    InvalidDatabaseTarget,
    #[error("admin database runtime role has unsafe privileges")]
    UnsafeRuntimeRole,
    #[error("idempotency key was already used for a different admin action")]
    IdempotencyConflict,
    #[error("admin web credential is not database-enforced read-only")]
    ReadCredentialWritable,
    #[error("admin API credential cannot write to the admin database")]
    WriteCredentialReadOnly,
    #[error("admin worker identifier is invalid")]
    InvalidWorkerId,
    #[error("admin action error code is invalid")]
    InvalidErrorCode,
    #[error("admin action lease is no longer current")]
    LeaseLost,
}

#[derive(Clone)]
pub struct AdminReadContext {
    connection: DatabaseConnection,
}

impl AdminReadContext {
    /// Connects and proves that `PostgreSQL` enforces a read-only session.
    ///
    /// # Errors
    ///
    /// Returns an error when the connection fails, the mode cannot be decoded,
    /// or the supplied credential can write.
    pub async fn connect(config: AdminDatabaseConfig<'_>) -> Result<Self, AdminOrmError> {
        let connection = Database::connect(config.connect_options()?)
            .await
            .map_err(AdminOrmError::Database)?;
        validate_runtime_role(&connection, &config).await?;
        if transaction_read_only(&connection).await? {
            Ok(Self { connection })
        } else {
            Err(AdminOrmError::ReadCredentialWritable)
        }
    }

    /// Checks that the admin database is reachable.
    ///
    /// # Errors
    ///
    /// Returns an error when the database cannot execute the probe.
    pub async fn ready(&self) -> Result<(), AdminOrmError> {
        ready(&self.connection).await
    }

    /// Loads the product-owned administrative grant.
    ///
    /// # Errors
    ///
    /// Returns an error when the query fails or the result cannot be decoded.
    pub async fn has_permission(
        &self,
        subject: &str,
        permission: AdminPermission,
    ) -> Result<bool, AdminOrmError> {
        has_permission(&self.connection, subject, permission).await
    }

    /// Returns bounded aggregate data for the admin dashboard.
    ///
    /// # Errors
    ///
    /// Returns an error when the query fails or the result cannot be decoded.
    pub async fn dashboard_stats(&self) -> Result<AdminDashboardStats, AdminOrmError> {
        let row = self
            .connection
            .query_one(Statement::from_string(
                DatabaseBackend::Postgres,
                r"
                    SELECT
                      (SELECT count(*) FROM admin_principals WHERE status = 'active')::bigint
                        AS active_admins,
                      (SELECT count(*) FROM admin_action_requests
                       WHERE status IN ('accepted', 'running'))::bigint AS pending_actions
                "
                .to_owned(),
            ))
            .await
            .map_err(AdminOrmError::Database)?
            .ok_or(AdminOrmError::Decode)?;
        Ok(AdminDashboardStats {
            active_admins: i64::try_get(&row, "", "active_admins")
                .map_err(|_| AdminOrmError::Decode)?,
            pending_actions: i64::try_get(&row, "", "pending_actions")
                .map_err(|_| AdminOrmError::Decode)?,
        })
    }
}

#[derive(Clone)]
pub struct AdminWriteContext {
    connection: DatabaseConnection,
}

impl AdminWriteContext {
    /// Connects and proves that the admin API credential is write-capable.
    ///
    /// # Errors
    ///
    /// Returns an error when the connection fails, the mode cannot be decoded,
    /// or the supplied credential is read-only.
    pub async fn connect(config: AdminDatabaseConfig<'_>) -> Result<Self, AdminOrmError> {
        let connection = Database::connect(config.connect_options()?)
            .await
            .map_err(AdminOrmError::Database)?;
        validate_runtime_role(&connection, &config).await?;
        if transaction_read_only(&connection).await? {
            Err(AdminOrmError::WriteCredentialReadOnly)
        } else {
            Ok(Self { connection })
        }
    }

    /// Checks that the admin database is reachable.
    ///
    /// # Errors
    ///
    /// Returns an error when the database cannot execute the probe.
    pub async fn ready(&self) -> Result<(), AdminOrmError> {
        ready(&self.connection).await
    }

    /// Loads the product-owned administrative grant.
    ///
    /// # Errors
    ///
    /// Returns an error when the query fails or the result cannot be decoded.
    pub async fn has_permission(
        &self,
        subject: &str,
        permission: AdminPermission,
    ) -> Result<bool, AdminOrmError> {
        has_permission(&self.connection, subject, permission).await
    }

    /// Records an idempotent administrative command before execution.
    ///
    /// # Errors
    ///
    /// Returns an error when the write fails or the operation id is invalid.
    pub async fn record_action(&self, input: &AdminAction<'_>) -> Result<Uuid, AdminOrmError> {
        let operation_id = Uuid::new_v4();
        let transaction = self
            .connection
            .begin()
            .await
            .map_err(AdminOrmError::Database)?;
        let inserted = transaction
            .query_one(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                r"
                    INSERT INTO admin_action_requests (
                        operation_id,
                        idempotency_key,
                        actor_subject,
                        actor_session_id,
                        resource,
                        action,
                        reason
                    ) VALUES ($1::uuid, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (idempotency_key) DO NOTHING
                    RETURNING operation_id::text AS operation_id
                ",
                [
                    operation_id.to_string().into(),
                    input.idempotency_key.into(),
                    input.actor_subject.into(),
                    input.actor_session_id.into(),
                    input.resource.into(),
                    input.action.into(),
                    input.reason.into(),
                ],
            ))
            .await
            .map_err(AdminOrmError::Database)?;
        let (operation_id, was_inserted) = if let Some(row) = inserted {
            (operation_id_from_row(&row)?, true)
        } else {
            let existing = transaction
                .query_one(Statement::from_sql_and_values(
                    DatabaseBackend::Postgres,
                    r"
                            SELECT operation_id::text AS operation_id
                            FROM admin_action_requests
                            WHERE idempotency_key = $1
                              AND actor_subject = $2
                              AND actor_session_id = $3
                              AND resource = $4
                              AND action = $5
                              AND reason = $6
                        ",
                    [
                        input.idempotency_key.into(),
                        input.actor_subject.into(),
                        input.actor_session_id.into(),
                        input.resource.into(),
                        input.action.into(),
                        input.reason.into(),
                    ],
                ))
                .await
                .map_err(AdminOrmError::Database)?;
            if let Some(row) = existing {
                (operation_id_from_row(&row)?, false)
            } else {
                transaction
                    .rollback()
                    .await
                    .map_err(AdminOrmError::Database)?;
                return Err(AdminOrmError::IdempotencyConflict);
            }
        };
        if was_inserted {
            transaction
                .execute(Statement::from_sql_and_values(
                    DatabaseBackend::Postgres,
                    r"
                        INSERT INTO admin_action_outbox (operation_id, event_kind)
                        VALUES ($1::uuid, 'admin.action.requested')
                    ",
                    [operation_id.to_string().into()],
                ))
                .await
                .map_err(AdminOrmError::Database)?;
        }
        transaction
            .commit()
            .await
            .map_err(AdminOrmError::Database)?;
        Ok(operation_id)
    }

    /// Claims at most one ready action using a database lease and
    /// `FOR UPDATE SKIP LOCKED`.
    ///
    /// Expired leases are eligible for a new token. Every completion must
    /// present the exact token returned here, fencing late workers after a
    /// reclaim.
    ///
    /// # Errors
    ///
    /// Returns an error for an invalid worker identifier, query failure, or
    /// malformed persisted action.
    pub async fn claim_action(
        &self,
        worker_id: &str,
    ) -> Result<Option<ClaimedAdminAction>, AdminOrmError> {
        if !valid_bounded_token(worker_id, 3, 64) {
            return Err(AdminOrmError::InvalidWorkerId);
        }
        let transaction = self
            .connection
            .begin()
            .await
            .map_err(AdminOrmError::Database)?;
        expire_exhausted_leases(&transaction).await?;
        let lease_token = Uuid::new_v4();
        let claimed = claim_next_action(&transaction, lease_token, worker_id).await?;
        let Some(row) = claimed else {
            transaction
                .commit()
                .await
                .map_err(AdminOrmError::Database)?;
            return Ok(None);
        };
        let claimed = claimed_action_from_row(&row)?;
        transaction
            .execute(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                "UPDATE admin_action_requests SET status = 'running' WHERE operation_id = $1::uuid",
                [claimed.operation_id.to_string().into()],
            ))
            .await
            .map_err(AdminOrmError::Database)?;
        transaction
            .commit()
            .await
            .map_err(AdminOrmError::Database)?;
        Ok(Some(claimed))
    }

    /// Completes a claimed action only while its exact lease token remains
    /// current. Retryable failures receive bounded exponential backoff and are
    /// dead-lettered after the reviewed retry limit.
    ///
    /// # Errors
    ///
    /// Returns [`AdminOrmError::LeaseLost`] for a stale completion, or a typed
    /// validation/database error.
    pub async fn complete_action(
        &self,
        operation_id: Uuid,
        lease_token: Uuid,
        outcome: AdminActionOutcome<'_>,
    ) -> Result<(), AdminOrmError> {
        if operation_id.is_nil() || lease_token.is_nil() {
            return Err(AdminOrmError::LeaseLost);
        }
        let error_code = match outcome {
            AdminActionOutcome::Succeeded => None,
            AdminActionOutcome::Rejected { error_code }
            | AdminActionOutcome::RetryableFailure { error_code } => {
                if !valid_bounded_token(error_code, 2, 64) {
                    return Err(AdminOrmError::InvalidErrorCode);
                }
                Some(error_code)
            }
        };
        let transaction = self
            .connection
            .begin()
            .await
            .map_err(AdminOrmError::Database)?;
        let lease = transaction
            .query_one(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                "SELECT attempts
                 FROM admin_action_outbox
                 WHERE operation_id = $1::uuid
                   AND lease_token = $2::uuid
                   AND delivery_status = 'delivering'
                   AND lease_expires_at > transaction_timestamp()
                 FOR UPDATE",
                [
                    operation_id.to_string().into(),
                    lease_token.to_string().into(),
                ],
            ))
            .await
            .map_err(AdminOrmError::Database)?
            .ok_or(AdminOrmError::LeaseLost)?;
        let attempts = i32::try_get(&lease, "", "attempts").map_err(|_| AdminOrmError::Decode)?;
        let terminal_retry = matches!(outcome, AdminActionOutcome::RetryableFailure { .. })
            && attempts >= MAX_RETRYABLE_FAILURES;

        let (delivery_status, request_status, completed, retry) = match outcome {
            AdminActionOutcome::Succeeded => ("delivered", "succeeded", true, false),
            AdminActionOutcome::Rejected { .. } => ("delivered", "rejected", true, false),
            AdminActionOutcome::RetryableFailure { .. } if terminal_retry => {
                ("dead_letter", "failed", true, false)
            }
            AdminActionOutcome::RetryableFailure { .. } => ("failed", "accepted", false, true),
        };
        let updated = transaction
            .execute(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                "UPDATE admin_action_outbox
                 SET delivery_status = $3,
                     available_at = CASE WHEN $4
                       THEN transaction_timestamp()
                         + make_interval(secs => LEAST(3600, (1 << LEAST(attempts, 11))))
                       ELSE available_at
                     END,
                     delivered_at = CASE WHEN $5 THEN transaction_timestamp() ELSE NULL END,
                     last_error_code = $6,
                     lease_token = NULL,
                     lease_expires_at = NULL,
                     claimed_by = NULL
                 WHERE operation_id = $1::uuid
                   AND lease_token = $2::uuid
                   AND delivery_status = 'delivering'",
                vec![
                    operation_id.to_string().into(),
                    lease_token.to_string().into(),
                    delivery_status.into(),
                    retry.into(),
                    completed.into(),
                    error_code.into(),
                ],
            ))
            .await
            .map_err(AdminOrmError::Database)?;
        if updated.rows_affected() != 1 {
            return Err(AdminOrmError::LeaseLost);
        }
        transaction
            .execute(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                "UPDATE admin_action_requests
                 SET status = $2,
                     completed_at = CASE WHEN $3 THEN transaction_timestamp() ELSE NULL END
                 WHERE operation_id = $1::uuid",
                vec![
                    operation_id.to_string().into(),
                    request_status.into(),
                    completed.into(),
                ],
            ))
            .await
            .map_err(AdminOrmError::Database)?;
        transaction.commit().await.map_err(AdminOrmError::Database)
    }
}

async fn expire_exhausted_leases(transaction: &DatabaseTransaction) -> Result<(), AdminOrmError> {
    transaction
        .execute(Statement::from_string(
            DatabaseBackend::Postgres,
            format!(
                r"
                    WITH exhausted AS (
                        UPDATE admin_action_outbox
                        SET delivery_status = 'dead_letter',
                            last_error_code = 'lease_attempts_exhausted',
                            lease_token = NULL,
                            lease_expires_at = NULL,
                            claimed_by = NULL
                        WHERE delivery_status = 'delivering'
                          AND lease_expires_at <= transaction_timestamp()
                          AND attempts >= {MAX_LEASE_ATTEMPTS}
                        RETURNING operation_id
                    )
                    UPDATE admin_action_requests
                    SET status = 'failed', completed_at = transaction_timestamp()
                    WHERE operation_id IN (SELECT operation_id FROM exhausted)
                "
            ),
        ))
        .await
        .map_err(AdminOrmError::Database)?;
    Ok(())
}

async fn claim_next_action(
    transaction: &DatabaseTransaction,
    lease_token: Uuid,
    worker_id: &str,
) -> Result<Option<sea_orm::QueryResult>, AdminOrmError> {
    transaction
        .query_one(Statement::from_sql_and_values(
            DatabaseBackend::Postgres,
            format!(
                r"
                    WITH candidate AS (
                        SELECT outbox.operation_id
                        FROM admin_action_outbox AS outbox
                        JOIN admin_action_requests AS request
                          ON request.operation_id = outbox.operation_id
                        WHERE (
                            (outbox.delivery_status IN ('pending', 'failed')
                              AND outbox.available_at <= transaction_timestamp())
                            OR (outbox.delivery_status = 'delivering'
                              AND outbox.lease_expires_at <= transaction_timestamp())
                        )
                          AND outbox.attempts < {MAX_LEASE_ATTEMPTS}
                          AND request.status IN ('accepted', 'running')
                        ORDER BY outbox.available_at, outbox.operation_id
                        FOR UPDATE OF outbox SKIP LOCKED
                        LIMIT 1
                    )
                    UPDATE admin_action_outbox AS outbox
                    SET delivery_status = 'delivering',
                        attempts = outbox.attempts + 1,
                        lease_token = $1::uuid,
                        lease_expires_at = transaction_timestamp() + interval '30 seconds',
                        claimed_by = $2,
                        last_error_code = NULL
                    FROM candidate, admin_action_requests AS request
                    WHERE outbox.operation_id = candidate.operation_id
                      AND request.operation_id = candidate.operation_id
                    RETURNING
                      outbox.operation_id::text AS operation_id,
                      outbox.lease_token::text AS lease_token,
                      outbox.attempts,
                      request.actor_subject,
                      request.resource,
                      request.action
                "
            ),
            [lease_token.to_string().into(), worker_id.into()],
        ))
        .await
        .map_err(AdminOrmError::Database)
}

fn claimed_action_from_row(
    row: &sea_orm::QueryResult,
) -> Result<ClaimedAdminAction, AdminOrmError> {
    Ok(ClaimedAdminAction {
        operation_id: operation_id_from_row(row)?,
        lease_token: uuid_from_row(row, "lease_token")?,
        actor_subject: String::try_get(row, "", "actor_subject")
            .map_err(|_| AdminOrmError::Decode)?,
        resource: String::try_get(row, "", "resource").map_err(|_| AdminOrmError::Decode)?,
        action: String::try_get(row, "", "action").map_err(|_| AdminOrmError::Decode)?,
        attempts: i32::try_get(row, "", "attempts").map_err(|_| AdminOrmError::Decode)?,
    })
}

fn operation_id_from_row(row: &sea_orm::QueryResult) -> Result<Uuid, AdminOrmError> {
    let value = String::try_get(row, "", "operation_id").map_err(|_| AdminOrmError::Decode)?;
    Uuid::parse_str(&value).map_err(|_| AdminOrmError::InvalidOperationId)
}

fn uuid_from_row(row: &sea_orm::QueryResult, column: &str) -> Result<Uuid, AdminOrmError> {
    let value = String::try_get(row, "", column).map_err(|_| AdminOrmError::Decode)?;
    Uuid::parse_str(&value).map_err(|_| AdminOrmError::InvalidOperationId)
}

fn valid_bounded_token(value: &str, minimum: usize, maximum: usize) -> bool {
    (minimum..=maximum).contains(&value.len())
        && value.bytes().enumerate().all(|(index, byte)| {
            if index == 0 {
                byte.is_ascii_lowercase()
            } else {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'_' | b'-' | b'.' | b':')
            }
        })
}

async fn ready(connection: &DatabaseConnection) -> Result<(), AdminOrmError> {
    connection
        .query_one(Statement::from_string(
            DatabaseBackend::Postgres,
            "SELECT 1 AS ready".to_owned(),
        ))
        .await
        .map_err(AdminOrmError::Database)?;
    Ok(())
}

async fn validate_runtime_role(
    connection: &DatabaseConnection,
    config: &AdminDatabaseConfig<'_>,
) -> Result<(), AdminOrmError> {
    let row = connection
        .query_one(Statement::from_string(
            DatabaseBackend::Postgres,
            r"
                SELECT
                    current_user::text AS role_name,
                    current_database()::text AS database_name,
                    role.rolsuper,
                    role.rolcreaterole,
                    role.rolcreatedb,
                    role.rolreplication,
                    role.rolbypassrls,
                    has_database_privilege(current_user, current_database(), 'CREATE')
                        AS can_create_schemas,
                    EXISTS (
                        SELECT 1
                        FROM information_schema.schemata AS schema
                        WHERE schema.schema_name <> 'information_schema'
                          AND schema.schema_name NOT LIKE 'pg_%'
                          AND has_schema_privilege(current_user, schema.schema_name, 'CREATE')
                    ) AS can_create_schema_objects
                FROM pg_roles AS role
                WHERE role.rolname = current_user
            "
            .to_owned(),
        ))
        .await
        .map_err(AdminOrmError::Database)?
        .ok_or(AdminOrmError::UnsafeRuntimeRole)?;
    let role_name = String::try_get(&row, "", "role_name").map_err(|_| AdminOrmError::Decode)?;
    let database_name =
        String::try_get(&row, "", "database_name").map_err(|_| AdminOrmError::Decode)?;
    let unsafe_role = [
        "rolsuper",
        "rolcreaterole",
        "rolcreatedb",
        "rolreplication",
        "rolbypassrls",
        "can_create_schemas",
        "can_create_schema_objects",
    ]
    .into_iter()
    .try_fold(false, |unsafe_role, column| {
        bool::try_get(&row, "", column)
            .map(|value| unsafe_role || value)
            .map_err(|_| AdminOrmError::Decode)
    })?;
    if role_name != config.expected_role || database_name != config.expected_database || unsafe_role
    {
        return Err(AdminOrmError::UnsafeRuntimeRole);
    }
    Ok(())
}

async fn transaction_read_only(connection: &DatabaseConnection) -> Result<bool, AdminOrmError> {
    let row = connection
        .query_one(Statement::from_string(
            DatabaseBackend::Postgres,
            "SHOW transaction_read_only".to_owned(),
        ))
        .await
        .map_err(AdminOrmError::Database)?
        .ok_or(AdminOrmError::Decode)?;
    let mode =
        String::try_get(&row, "", "transaction_read_only").map_err(|_| AdminOrmError::Decode)?;
    match mode.as_str() {
        "on" => Ok(true),
        "off" => Ok(false),
        _ => Err(AdminOrmError::Decode),
    }
}

async fn has_permission(
    connection: &DatabaseConnection,
    subject: &str,
    permission: AdminPermission,
) -> Result<bool, AdminOrmError> {
    let row = connection
        .query_one(Statement::from_sql_and_values(
            DatabaseBackend::Postgres,
            r"
                SELECT EXISTS (
                    SELECT 1
                    FROM admin_principals
                    WHERE shared_auth_subject = $1
                      AND status = 'active'
                      AND ($2 = ANY(permissions) OR 'super_admin' = ANY(permissions))
                ) AS allowed
            ",
            [subject.into(), permission.as_str().into()],
        ))
        .await
        .map_err(AdminOrmError::Database)?;
    row.map(|result| bool::try_get(&result, "", "allowed"))
        .transpose()
        .map_err(|_| AdminOrmError::Decode)
        .map(|allowed| allowed.unwrap_or(false))
}

#[cfg(test)]
mod tests {
    use sea_orm::{ConnectionTrait, Database, DatabaseBackend, Statement, TryGetable};
    use uuid::Uuid;

    use super::{
        AdminAction, AdminActionOutcome, AdminDatabaseConfig, AdminOrmError, AdminPermission,
        AdminWriteContext,
    };

    #[test]
    fn permissions_have_stable_database_values() {
        assert_eq!(AdminPermission::Read.as_str(), "admin:read");
        assert_eq!(AdminPermission::Write.as_str(), "admin:write");
    }

    #[test]
    fn database_target_requires_exact_identity_and_verified_tls() {
        let valid = AdminDatabaseConfig {
            database_url: "postgresql://admin_api_runtime:secret@admin-db.example/admin_control?sslmode=verify-full",
            expected_host: "admin-db.example",
            expected_database: "admin_control",
            expected_role: "admin_api_runtime",
        };
        assert!(valid.validate().is_ok());
        assert!(
            AdminDatabaseConfig {
                database_url: "postgresql://admin_api_runtime:secret@customer-db.example/admin_control?sslmode=verify-full",
                ..valid
            }
            .validate()
            .is_err()
        );
        assert!(
            AdminDatabaseConfig {
                database_url:
                    "postgresql://admin_api_runtime:secret@admin-db.example/admin_control?sslmode=require",
                ..valid
            }
            .validate()
            .is_err()
        );
    }

    #[tokio::test]
    async fn worker_lease_fences_stale_completion() {
        let Ok(database_url) = std::env::var("HHM_TEST_ADMIN_DATABASE_URL") else {
            eprintln!("skipping admin outbox integration test: database URL is not configured");
            return;
        };
        let connection = Database::connect(database_url)
            .await
            .expect("admin test database connection");
        let context = AdminWriteContext {
            connection: connection.clone(),
        };
        let actor = format!("test-admin-{}", Uuid::new_v4());
        connection
            .execute(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                "INSERT INTO admin_principals (shared_auth_subject, status, permissions)
                 VALUES ($1, 'active', ARRAY['admin:write'])",
                [actor.as_str().into()],
            ))
            .await
            .expect("admin principal");
        let idempotency_key = format!("admin-test-{}", Uuid::new_v4());
        let operation_id = context
            .record_action(&AdminAction {
                idempotency_key: &idempotency_key,
                actor_subject: &actor,
                actor_session_id: "test-session",
                resource: "application:00000000-0000-0000-0000-000000000001",
                action: "intake.application.start_review",
                reason: "Verify fenced admin outbox completion",
            })
            .await
            .expect("record admin action");
        let claimed = context
            .claim_action("worker-test-1")
            .await
            .expect("claim action")
            .expect("one ready action");
        assert_eq!(claimed.operation_id(), operation_id);
        assert_eq!(claimed.attempts(), 1);
        assert!(
            context
                .claim_action("worker-test-2")
                .await
                .expect("second claim")
                .is_none()
        );
        assert!(matches!(
            context
                .complete_action(operation_id, Uuid::new_v4(), AdminActionOutcome::Succeeded,)
                .await,
            Err(AdminOrmError::LeaseLost)
        ));
        context
            .complete_action(
                operation_id,
                claimed.lease_token(),
                AdminActionOutcome::Succeeded,
            )
            .await
            .expect("complete current lease");

        let row = connection
            .query_one(Statement::from_sql_and_values(
                DatabaseBackend::Postgres,
                "SELECT request.status AS request_status,
                        outbox.delivery_status AS delivery_status
                 FROM admin_action_requests AS request
                 JOIN admin_action_outbox AS outbox USING (operation_id)
                 WHERE request.operation_id = $1::uuid",
                [operation_id.to_string().into()],
            ))
            .await
            .expect("load completed action")
            .expect("completed action row");
        assert_eq!(
            String::try_get(&row, "", "request_status").expect("request status"),
            "succeeded"
        );
        assert_eq!(
            String::try_get(&row, "", "delivery_status").expect("delivery status"),
            "delivered"
        );
    }
}
