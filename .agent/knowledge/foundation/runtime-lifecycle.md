# Runtime Lifecycle

## What it establishes

Application shutdown is coordinated through the `AppServices` container so HTTP serving, background workers, and DB connections stop in dependency-safe order.

## Files

- `src/InventoryAllocationSimulator.jl` — `run_server!`, `main`, and shutdown hook wiring
- `src/services.jl` — `shutdown!(services)` and `install_shutdown_hook!(services)`
- `src/db/connection.jl` — DB connection close primitive
- `src/jobs/worker.jl` — job worker start/stop lifecycle primitive
- `tests/unit/setup/test_lifecycle_migrations_ci.jl` — lifecycle behavior coverage

## When to read this

Before writing any code that:
- Starts or stops the Genie server
- Starts background workers or long-running tasks
- Holds DB/cache/analytics resources in `AppServices`
- Adds a new service that needs shutdown cleanup

## Contract

- Build dependencies through `build_services(config)` and pass the resulting container to routes/jobs.
- Use `shutdown!(services)` for teardown; do not close DB connections or stop workers ad hoc from entrypoints.
- `shutdown!` stops background workers before closing the DB connection.
- `run_server!` installs an `atexit` shutdown hook and can optionally start workers with `start_jobs = true`.
- Tests should exercise lifecycle with injected services and `stop_http = false` unless they intentionally start a real server.

## Cross-references

- PRD §9 Project Structure
- PRD §10 Deployment
- `.agent/knowledge/foundation/service-dependency-injection.md`
