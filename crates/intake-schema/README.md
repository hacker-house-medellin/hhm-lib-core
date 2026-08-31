# HHaus generated SeaORM intake entities

This crate is generated from `schema/schema.sql` after materializing the declarative schema in PostgreSQL. It contains table/relationship shape only. Named authorization-aware operations belong in `hhm-orm-core`; services must not receive an unrestricted connection or generic CRUD surface through this crate.

Generation command (SeaORM CLI 2.0.2):

```bash
sea-orm-cli generate entity \
  --database-url "$TEMP_DATABASE_URL" \
  --database-schema public \
  --tables hhm_pre_interests,hhm_intake_uploads,hhm_applications,hhm_referrals,hhm_submission_outbox,hhm_user_points_accounts,hhm_user_points_ledger \
  --output-dir crates/intake-schema/src \
  --lib --with-serde both --serde-skip-deserializing-primary-key \
  --banner-version patch --er-diagram
```
