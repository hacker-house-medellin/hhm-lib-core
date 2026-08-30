# Generated Diesel schema

`schema.rs` was generated from a PostgreSQL 15 database materialized from `../schema.sql` with Diesel CLI 2.3.12:

```bash
diesel print-schema \
  --database-url "$TEMP_DATABASE_URL" \
  --schema public \
  --with-docs \
  --allow-tables-to-appear-in-same-query-config fk_related_tables \
  > schema/diesel/schema.rs
```

Do not hand-edit this file. Regeneration drift is a schema-authority failure.

