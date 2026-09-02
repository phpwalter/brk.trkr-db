# BrickTrackr Forward-Only Migrations

`bootstrap.sql` remains the authoritative fresh-database installer.

Databases already deployed from baseline `master-schema-v10.0` must advance only
through migration files recorded in `MIGRATION_MANIFEST.json`.

## Naming

Use six-digit monotonic IDs:

`000001__short_description.sql`

Migration IDs are never reused, reordered, renamed, or edited after release.

## Required manifest fields

Each migration entry contains:

- `id` — positive integer matching the filename prefix.
- `file` — migration filename.
- `name` — stable descriptive name.
- `sha256` — SHA-256 of the exact file bytes.
- `transaction_mode` — `transactional` or `nontransactional`.
- `release_label` — optional application/schema release label.
- `reason` — required for every nontransactional migration.

## Transaction ownership

Migration files must not contain `BEGIN`, `COMMIT`, or `ROLLBACK`. The migration
runner owns transaction boundaries.

Use `transactional` unless PostgreSQL requires otherwise. Nontransactional
migrations are exceptional and must explain why in the manifest.

## Release workflow

1. Create the next numbered migration from `_template.sql.example`.
2. Add it to `MIGRATION_MANIFEST.json`.
3. Run `python tools/verify_migrations.py`.
4. Test bootstrap on a fresh database.
5. Test upgrade from the previous production release using
   `python tools/apply_migrations.py --database "<dsn>" --dry-run`, then without
   `--dry-run`.
6. Run the complete schema/security contract validation suite.
7. Release the migration and manifest together.
8. After release, never edit the migration. A checksum mismatch against an
   applied production row is a hard failure; create a new corrective migration.

The migration runner serializes application with a PostgreSQL advisory lock,
checks the installed baseline, proves that applied history is an exact prefix
of the local manifest, compares every applied checksum, and only then executes
pending migrations.


## Deployment role requirement

The login used by `tools/apply_migrations.py` must be granted membership in
`brktrkr_migrator`. The migration runner executes schema changes with `SET ROLE brktrkr_owner`.
Normal runtime, admin, importer, and reporting logins must never be members of
`brktrkr_migrator` or `brktrkr_owner`.
