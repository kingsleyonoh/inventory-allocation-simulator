# Core Config Loading

## What it establishes

Runtime configuration is loaded once from environment variables into typed, validated `AppConfig` sections before server, CLI, or service wiring code runs.

## Files

- `config/app.jl` — typed config structs, `.env` loading, parsing, and validation
- `src/InventoryAllocationSimulator.jl` — includes and exports the config loader
- `tests/unit/setup/test_config_and_wiring.jl` — behavior and validation coverage

## When to read this

Before writing any code that:
- Adds or consumes an environment variable
- Starts the Genie server or a CLI command
- Configures DB, Redis, DuckDB, jobs, integrations, or observability

## Contract

- Read config through `load_config(env)` or from `run_server!`/CLI defaults; do not read raw `ENV` throughout business modules.
- Required runtime values (`DATABASE_URL`, `REDIS_URL`, `DUCKDB_PATH`, `SESSION_SECRET`, `METRICS_TOKEN`) fail fast with `ArgumentError` when blank.
- Boolean, integer, port, and bounded float settings are parsed by the central loader so invalid values fail before side effects begin.
- `.env` files are local-only; committed documentation belongs in `.env.example` with placeholders only.

## Cross-references

- PRD §14 Environment Variables
- `.agent/rules/CODING_STANDARDS_SECURITY.md` Secrets Management
