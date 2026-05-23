# DB Migration Runner

## What it establishes

Database migrations are discovered from ordered `*.up.sql` / `*.down.sql` files, executed through a store abstraction, and exposed to DB health/readiness checks.

## Files

- `src/db/migrations.jl` — migration discovery, ordered up/down execution, SQL store, memory store, and health status
- `scripts/migrate.jl` — CLI entrypoint for `julia --project scripts/migrate.jl up|down`
- `config/routes.jl` — `/health/db` migration readiness response
- `tests/unit/setup/test_lifecycle_migrations_ci.jl` — ordered migration and health coverage
- `tests/integration/setup/test_migration_runner_cli.jl` — CLI validation and DB health response coverage

## When to read this

Before writing any code that:
- Adds a migration file under `migrations/`
- Changes DB startup, health checks, or readiness behavior
- Calls migration state from deployment, CI, tests, or observability

## Contract

- Migration filenames must be `NNN_name.up.sql` and optionally `NNN_name.down.sql`.
- `up` applies pending migrations in ascending version order.
- `down` reverts applied migrations in descending version order and requires a matching down SQL file.
- Production DB execution uses `SqlMigrationStore`; unit tests may use `MemoryMigrationStore` to prove ordering without opening network connections.
- `/health/db` reports `ok` only when PostgreSQL is reachable and no migrations are pending.

## Cross-references

- PRD §10 Deployment
- PRD §10b Health Checks
- `.agent/knowledge/foundation/core-config-loading.md`
