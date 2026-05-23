# Service Dependency Injection

## What it establishes

Application entrypoints build one `AppServices` container that carries typed DB, Redis, DuckDB, jobs, and observability services from validated config into routes and future workers.

## Files

- `src/services.jl` — `AppServices` and `build_services(config)`
- `src/db/connection.jl` — DB, cache, and analytics service primitives
- `src/jobs/worker.jl` — job service primitive
- `src/observability/logging.jl` — observability service primitive
- `config/routes.jl` — route registration accepts injected services
- `src/InventoryAllocationSimulator.jl` — `run_server!` builds services and registers routes
- `tests/unit/setup/test_config_and_wiring.jl` — wiring coverage

## When to read this

Before writing any code that:
- Creates or consumes service dependencies
- Adds routes, workers, or modules needing DB/cache/analytics/logging
- Changes server startup or route registration

## Contract

- Build services through `build_services(config)` after `load_config`; do not instantiate ad-hoc service singletons inside handlers.
- Service construction is side-effect-light: DB network connections open only when `connect!(db)` is called.
- Route registration receives the service container so future route handlers can use injected dependencies instead of raw globals.
- Close DB services with `close!(db)` when adding lifecycle/shutdown behavior.

## Cross-references

- PRD §9 Project Structure dependency hierarchy
- PRD §10 Deployment
- PRD §10b Observability Stack
