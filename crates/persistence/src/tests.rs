use super::*;
use chrono::{DateTime, Utc};
use hhm_interfaces::{CreateReservation, ReservationStatus};
use sea_orm::{DatabaseBackend, DbErr, MockDatabase, MockExecResult};
use uuid::Uuid;

const TENANT_ID: &str = "tenant-medellin";
const USER_ID: &str = "user-018f";
const SERVICE_ID: &str = "hhm-api-server.rs";

fn timestamp(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .expect("test timestamp must be valid")
        .with_timezone(&Utc)
}

fn context(capability: ReservationCapability) -> PersistenceContext {
    PersistenceContext::try_new(TENANT_ID, USER_ID, SERVICE_ID, [capability])
        .expect("synthetic context must be valid")
}

fn create_request() -> CreateReservation {
    CreateReservation {
        title: "Secure systems workshop".into(),
        summary: "A bounded persistence exercise".into(),
        member_name: "Synthetic Resident".into(),
        space_name: "Workshop Room".into(),
        starts_at: timestamp("2026-09-01T15:00:00Z"),
        ends_at: timestamp("2026-09-01T17:00:00Z"),
    }
}

fn stored_row(status: &str) -> reservation::Model {
    reservation::Model {
        id: Uuid::parse_str("018f0000-0000-7000-8000-000000000001")
            .expect("synthetic UUID must be valid"),
        tenant_id: TENANT_ID.into(),
        user_id: USER_ID.into(),
        service_id: SERVICE_ID.into(),
        title: "Secure systems workshop".into(),
        summary: "A bounded persistence exercise".into(),
        member_name: "Synthetic Resident".into(),
        space_name: "Workshop Room".into(),
        starts_at: timestamp("2026-09-01T15:00:00Z"),
        ends_at: timestamp("2026-09-01T17:00:00Z"),
        status: status.into(),
        created_at: timestamp("2026-08-25T20:00:00Z"),
        updated_at: timestamp("2026-08-25T20:00:00Z"),
    }
}

fn transaction_sql(database: sea_orm::DatabaseConnection) -> String {
    database
        .into_transaction_log()
        .into_iter()
        .flat_map(|transaction| {
            transaction
                .statements()
                .iter()
                .map(|statement| statement.sql.clone())
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn context_rejects_missing_or_ambiguous_identity_dimensions() {
    for (tenant_id, user_id, service_id) in [
        ("", USER_ID, SERVICE_ID),
        (TENANT_ID, "", SERVICE_ID),
        (TENANT_ID, USER_ID, ""),
        (" tenant-medellin", USER_ID, SERVICE_ID),
        (TENANT_ID, "user/../../other", SERVICE_ID),
    ] {
        let error = PersistenceContext::try_new(
            tenant_id,
            user_id,
            service_id,
            [ReservationCapability::Read],
        )
        .expect_err("invalid identity context must fail closed");
        assert_eq!(error.kind(), PersistenceErrorKind::InvalidContext);
    }
}

#[test]
fn context_rejects_an_empty_capability_set() {
    let error = PersistenceContext::try_new(TENANT_ID, USER_ID, SERVICE_ID, [])
        .expect_err("an unscoped context must fail closed");
    assert_eq!(error.kind(), PersistenceErrorKind::MissingCapability);
}

#[tokio::test]
async fn read_capability_cannot_create_and_touches_no_database_state() {
    let database = MockDatabase::new(DatabaseBackend::Postgres).into_connection();
    let store = ReservationStore::new(&database);
    let error = store
        .create(
            &context(ReservationCapability::Read),
            create_request(),
            Uuid::new_v4(),
            timestamp("2026-08-25T20:00:00Z"),
        )
        .await
        .expect_err("read-only context must not create records");
    assert_eq!(error.kind(), PersistenceErrorKind::MissingCapability);
    assert!(database.into_transaction_log().is_empty());
}

#[tokio::test]
async fn create_capability_cannot_read_and_touches_no_database_state() {
    let database = MockDatabase::new(DatabaseBackend::Postgres).into_connection();
    let store = ReservationStore::new(&database);
    let error = store
        .find_by_id(&context(ReservationCapability::Create), Uuid::new_v4())
        .await
        .expect_err("create-only context must not read records");
    assert_eq!(error.kind(), PersistenceErrorKind::MissingCapability);
    assert!(database.into_transaction_log().is_empty());
}

#[tokio::test]
async fn create_persists_every_scope_dimension_in_one_transaction() {
    let database = MockDatabase::new(DatabaseBackend::Postgres)
        .append_exec_results([MockExecResult {
            last_insert_id: 0,
            rows_affected: 1,
        }])
        .into_connection();
    let store = ReservationStore::new(&database);
    let id = Uuid::parse_str("018f0000-0000-7000-8000-000000000001")
        .expect("synthetic UUID must be valid");
    let created = store
        .create(
            &context(ReservationCapability::Create),
            create_request(),
            id,
            timestamp("2026-08-25T20:00:00Z"),
        )
        .await
        .expect("scoped create must succeed");

    assert_eq!(created.id, id);
    assert_eq!(created.status, ReservationStatus::Requested);
    let sql = transaction_sql(database);
    assert!(sql.contains("BEGIN"));
    assert!(sql.contains("INSERT INTO \"hhm_reservations\""));
    assert!(sql.contains("\"tenant_id\""));
    assert!(sql.contains("\"user_id\""));
    assert!(sql.contains("\"service_id\""));
    assert!(sql.contains("COMMIT"));
}

#[tokio::test]
async fn read_uses_a_read_only_transaction_and_all_scope_predicates() {
    let database = MockDatabase::new(DatabaseBackend::Postgres)
        .append_exec_results([MockExecResult {
            last_insert_id: 0,
            rows_affected: 0,
        }])
        .append_query_results([[stored_row("requested")]])
        .into_connection();
    let store = ReservationStore::new(&database);
    let found = store
        .find_by_id(
            &context(ReservationCapability::Read),
            stored_row("requested").id,
        )
        .await
        .expect("scoped read must succeed")
        .expect("synthetic row must exist");

    assert_eq!(found.status, ReservationStatus::Requested);
    let sql = transaction_sql(database);
    assert!(sql.contains("SET TRANSACTION READ ONLY"));
    assert!(sql.contains("FROM \"hhm_reservations\""));
    assert!(sql.contains("WHERE \"hhm_reservations\".\"id\" ="));
    assert!(sql.contains("AND \"hhm_reservations\".\"tenant_id\" ="));
    assert!(sql.contains("AND \"hhm_reservations\".\"user_id\" ="));
    assert!(sql.contains("AND \"hhm_reservations\".\"service_id\" ="));
    assert!(sql.contains("ROLLBACK"));
}

#[tokio::test]
async fn invalid_reservation_interval_fails_before_database_access() {
    let database = MockDatabase::new(DatabaseBackend::Postgres).into_connection();
    let store = ReservationStore::new(&database);
    let mut request = create_request();
    request.ends_at = request.starts_at;
    let error = store
        .create(
            &context(ReservationCapability::Create),
            request,
            Uuid::new_v4(),
            timestamp("2026-08-25T20:00:00Z"),
        )
        .await
        .expect_err("an empty interval must fail closed");
    assert_eq!(error.kind(), PersistenceErrorKind::InvalidReservation);
    assert!(database.into_transaction_log().is_empty());
}

#[tokio::test]
async fn corrupt_stored_status_fails_closed_without_echoing_the_value() {
    let database = MockDatabase::new(DatabaseBackend::Postgres)
        .append_exec_results([MockExecResult {
            last_insert_id: 0,
            rows_affected: 0,
        }])
        .append_query_results([[stored_row("administrator")]])
        .into_connection();
    let store = ReservationStore::new(&database);
    let error = store
        .find_by_id(
            &context(ReservationCapability::Read),
            stored_row("administrator").id,
        )
        .await
        .expect_err("unknown stored status must not be accepted");
    assert_eq!(error.kind(), PersistenceErrorKind::CorruptRecord);
    assert!(!format!("{error:?}").contains("administrator"));
    assert!(!error.to_string().contains("administrator"));
}

#[tokio::test]
async fn database_errors_are_redacted() {
    let database = MockDatabase::new(DatabaseBackend::Postgres)
        .append_exec_errors([DbErr::Custom("password=synthetic-do-not-echo".into())])
        .into_connection();
    let store = ReservationStore::new(&database);
    let error = store
        .create(
            &context(ReservationCapability::Create),
            create_request(),
            Uuid::new_v4(),
            timestamp("2026-08-25T20:00:00Z"),
        )
        .await
        .expect_err("database error must fail closed");
    assert_eq!(error.kind(), PersistenceErrorKind::Database);
    assert!(!format!("{error:?}").contains("synthetic-do-not-echo"));
    assert!(!error.to_string().contains("synthetic-do-not-echo"));
}
