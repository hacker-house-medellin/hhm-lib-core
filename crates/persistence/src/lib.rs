//! Product-owned, explicitly scoped persistence for Hacker House Medellín.
//!
//! Authentication and product authorization happen outside this crate. Callers
//! must derive [`PersistenceContext`] from a verified identity, an authorized
//! product tenant membership, and the independently authenticated calling
//! service. This crate then makes those three dimensions mandatory in every
//! reservation query and fails closed when any dimension or capability is
//! missing.

use chrono::{DateTime, Utc};
use hhm_interfaces::{CreateReservation, Reservation, ReservationStatus};
use sea_orm::{
    ColumnTrait, ConnectionTrait, DatabaseConnection, DbBackend, DbErr, EntityTrait, QueryFilter,
    Set, Statement, TransactionTrait,
};
use std::collections::BTreeSet;
use std::fmt;
use uuid::Uuid;

mod reservation {
    use sea_orm::entity::prelude::*;

    #[derive(Clone, Debug, PartialEq, DeriveEntityModel)]
    #[sea_orm(table_name = "hhm_reservations")]
    pub struct Model {
        #[sea_orm(primary_key, auto_increment = false)]
        pub id: Uuid,
        pub tenant_id: String,
        pub user_id: String,
        pub service_id: String,
        pub title: String,
        pub summary: String,
        pub member_name: String,
        pub space_name: String,
        pub starts_at: DateTimeUtc,
        pub ends_at: DateTimeUtc,
        pub status: String,
        pub created_at: DateTimeUtc,
        pub updated_at: DateTimeUtc,
    }

    #[derive(Copy, Clone, Debug, EnumIter, DeriveRelation)]
    pub enum Relation {}

    impl ActiveModelBehavior for ActiveModel {}
}

/// A product-local capability proven before persistence is invoked.
///
/// Capabilities are intentionally independent. A caller allowed to create a
/// reservation does not implicitly receive permission to read it back.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum ReservationCapability {
    Read,
    Create,
}

/// The three independent identity dimensions required by persistence.
///
/// Identifiers are kept private and redacted from `Debug`. Construction checks
/// bounded, canonical identifier shapes and rejects an empty capability set;
/// it does not replace upstream cryptographic authentication or product-owned
/// membership authorization.
#[derive(Clone, Eq, PartialEq)]
pub struct PersistenceContext {
    tenant_id: Box<str>,
    user_id: Box<str>,
    service_id: Box<str>,
    capabilities: BTreeSet<ReservationCapability>,
}

impl PersistenceContext {
    pub fn try_new<I>(
        tenant_id: impl Into<String>,
        user_id: impl Into<String>,
        service_id: impl Into<String>,
        capabilities: I,
    ) -> Result<Self, PersistenceError>
    where
        I: IntoIterator<Item = ReservationCapability>,
    {
        let tenant_id = tenant_id.into();
        let user_id = user_id.into();
        let service_id = service_id.into();
        if !valid_identifier(&tenant_id)
            || !valid_identifier(&user_id)
            || !valid_identifier(&service_id)
        {
            return Err(PersistenceError::new(PersistenceErrorKind::InvalidContext));
        }

        let capabilities = capabilities.into_iter().collect::<BTreeSet<_>>();
        if capabilities.is_empty() {
            return Err(PersistenceError::new(
                PersistenceErrorKind::MissingCapability,
            ));
        }

        Ok(Self {
            tenant_id: tenant_id.into_boxed_str(),
            user_id: user_id.into_boxed_str(),
            service_id: service_id.into_boxed_str(),
            capabilities,
        })
    }

    fn require(&self, capability: ReservationCapability) -> Result<(), PersistenceError> {
        if self.capabilities.contains(&capability) {
            Ok(())
        } else {
            Err(PersistenceError::new(
                PersistenceErrorKind::MissingCapability,
            ))
        }
    }
}

impl fmt::Debug for PersistenceContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PersistenceContext")
            .field("tenant_id", &"[redacted]")
            .field("user_id", &"[redacted]")
            .field("service_id", &"[redacted]")
            .field("capabilities", &self.capabilities)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PersistenceErrorKind {
    InvalidContext,
    MissingCapability,
    InvalidReservation,
    CorruptRecord,
    Database,
}

/// A deliberately redacted persistence failure.
///
/// Raw database errors can contain topology or configuration details, so this
/// boundary converts them to a stable non-probing category.
#[derive(Clone, Eq, PartialEq)]
pub struct PersistenceError {
    kind: PersistenceErrorKind,
}

impl PersistenceError {
    fn new(kind: PersistenceErrorKind) -> Self {
        Self { kind }
    }

    pub const fn kind(&self) -> PersistenceErrorKind {
        self.kind
    }
}

impl fmt::Debug for PersistenceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PersistenceError")
            .field("kind", &self.kind)
            .finish()
    }
}

impl fmt::Display for PersistenceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self.kind {
            PersistenceErrorKind::InvalidContext => "invalid persistence context",
            PersistenceErrorKind::MissingCapability => "persistence capability denied",
            PersistenceErrorKind::InvalidReservation => "invalid reservation",
            PersistenceErrorKind::CorruptRecord => "invalid stored reservation",
            PersistenceErrorKind::Database => "persistence unavailable",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for PersistenceError {}

impl From<DbErr> for PersistenceError {
    fn from(_: DbErr) -> Self {
        Self::new(PersistenceErrorKind::Database)
    }
}

/// Reservation persistence that always applies tenant, user, and service
/// predicates. The raw SeaORM entity remains private so consumers cannot bypass
/// this boundary accidentally.
pub struct ReservationStore<'database> {
    database: &'database DatabaseConnection,
}

impl<'database> ReservationStore<'database> {
    pub const fn new(database: &'database DatabaseConnection) -> Self {
        Self { database }
    }

    pub async fn create(
        &self,
        context: &PersistenceContext,
        request: CreateReservation,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<Reservation, PersistenceError> {
        context.require(ReservationCapability::Create)?;
        request
            .validate()
            .map_err(|_| PersistenceError::new(PersistenceErrorKind::InvalidReservation))?;
        if request.ends_at <= request.starts_at {
            return Err(PersistenceError::new(
                PersistenceErrorKind::InvalidReservation,
            ));
        }

        let reservation = request
            .into_record(id, now)
            .map_err(|_| PersistenceError::new(PersistenceErrorKind::InvalidReservation))?;
        let active_model = reservation::ActiveModel {
            id: Set(reservation.id),
            tenant_id: Set(context.tenant_id.to_string()),
            user_id: Set(context.user_id.to_string()),
            service_id: Set(context.service_id.to_string()),
            title: Set(reservation.title.clone()),
            summary: Set(reservation.summary.clone()),
            member_name: Set(reservation.member_name.clone()),
            space_name: Set(reservation.space_name.clone()),
            starts_at: Set(reservation.starts_at),
            ends_at: Set(reservation.ends_at),
            status: Set(status_to_wire(reservation.status).into()),
            created_at: Set(reservation.created_at),
            updated_at: Set(reservation.updated_at),
        };

        let transaction = self
            .database
            .begin()
            .await
            .map_err(PersistenceError::from)?;
        if let Err(error) = reservation::Entity::insert(active_model)
            .exec_without_returning(&transaction)
            .await
        {
            let _ = transaction.rollback().await;
            return Err(PersistenceError::from(error));
        }
        transaction.commit().await.map_err(PersistenceError::from)?;
        Ok(reservation)
    }

    pub async fn find_by_id(
        &self,
        context: &PersistenceContext,
        id: Uuid,
    ) -> Result<Option<Reservation>, PersistenceError> {
        context.require(ReservationCapability::Read)?;
        if self.database.get_database_backend() != DbBackend::Postgres {
            return Err(PersistenceError::new(PersistenceErrorKind::Database));
        }

        let transaction = self
            .database
            .begin()
            .await
            .map_err(PersistenceError::from)?;
        if let Err(error) = transaction
            .execute_raw(Statement::from_string(
                DbBackend::Postgres,
                "SET TRANSACTION READ ONLY",
            ))
            .await
        {
            let _ = transaction.rollback().await;
            return Err(PersistenceError::from(error));
        }

        let query_result = reservation::Entity::find_by_id(id)
            .filter(reservation::Column::TenantId.eq(context.tenant_id.as_ref()))
            .filter(reservation::Column::UserId.eq(context.user_id.as_ref()))
            .filter(reservation::Column::ServiceId.eq(context.service_id.as_ref()))
            .one(&transaction)
            .await;
        let rollback_result = transaction.rollback().await;
        if rollback_result.is_err() {
            return Err(PersistenceError::new(PersistenceErrorKind::Database));
        }

        let model = query_result.map_err(PersistenceError::from)?;
        model
            .map(|model| {
                if model.id != id
                    || model.tenant_id != context.tenant_id.as_ref()
                    || model.user_id != context.user_id.as_ref()
                    || model.service_id != context.service_id.as_ref()
                {
                    return Err(PersistenceError::new(PersistenceErrorKind::CorruptRecord));
                }
                model.try_into()
            })
            .transpose()
    }
}

impl TryFrom<reservation::Model> for Reservation {
    type Error = PersistenceError;

    fn try_from(model: reservation::Model) -> Result<Self, Self::Error> {
        let status = status_from_wire(&model.status)
            .ok_or_else(|| PersistenceError::new(PersistenceErrorKind::CorruptRecord))?;
        if model.ends_at <= model.starts_at {
            return Err(PersistenceError::new(PersistenceErrorKind::CorruptRecord));
        }
        Ok(Self {
            id: model.id,
            title: model.title,
            summary: model.summary,
            member_name: model.member_name,
            space_name: model.space_name,
            starts_at: model.starts_at,
            ends_at: model.ends_at,
            status,
            created_at: model.created_at,
            updated_at: model.updated_at,
        })
    }
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.contains("..")
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}

const fn status_to_wire(status: ReservationStatus) -> &'static str {
    match status {
        ReservationStatus::Requested => "requested",
        ReservationStatus::Confirmed => "confirmed",
        ReservationStatus::CheckedIn => "checked_in",
        ReservationStatus::Completed => "completed",
        ReservationStatus::Cancelled => "cancelled",
    }
}

fn status_from_wire(value: &str) -> Option<ReservationStatus> {
    match value {
        "requested" => Some(ReservationStatus::Requested),
        "confirmed" => Some(ReservationStatus::Confirmed),
        "checked_in" => Some(ReservationStatus::CheckedIn),
        "completed" => Some(ReservationStatus::Completed),
        "cancelled" => Some(ReservationStatus::Cancelled),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
