//! Compile-time witness for the immutable platform contract projections.
//!
//! Source files remain byte-identical to the production `hhm-interfaces`
//! revision. The build script strips only generator-level inner attributes in
//! its disposable build output so all Rust, SeaORM, and Diesel projections are
//! compiled together without altering the vendored evidence.

#![forbid(unsafe_code)]

#[macro_use]
extern crate diesel;

#[allow(dead_code, unused_imports)]
pub mod types {
    include!(concat!(env!("OUT_DIR"), "/types.rs"));
}

#[allow(dead_code, unused_imports)]
pub mod seaorm {
    include!(concat!(env!("OUT_DIR"), "/entities.rs"));
}

#[allow(dead_code, unused_imports)]
pub mod diesel_lane {
    include!(concat!(env!("OUT_DIR"), "/schema.rs"));
}

pub use diesel_lane::{schema, sql_types};

#[cfg(test)]
mod tests {
    use super::types::{AccessDecisionOutcome, ReservationStatus};

    #[test]
    fn generated_enum_wire_values_are_available() {
        assert_eq!(
            serde_json::to_string(&ReservationStatus::Confirmed).expect("serialize status"),
            "\"confirmed\""
        );
        assert_eq!(
            serde_json::to_string(&AccessDecisionOutcome::Denied).expect("serialize decision"),
            "\"denied\""
        );
    }
}
