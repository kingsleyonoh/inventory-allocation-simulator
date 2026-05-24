# Simulation Lifecycle Foundation

## What it establishes

Simulation runs are tenant-scoped lifecycle records whose input snapshots are frozen at creation, then processed by idempotent workers that generate deterministic demand scenarios without rereading mutable planning data for completed-run detail.

## Files

- `src/planning/snapshots.jl` — frozen planning snapshot capture.
- `src/planning/forecasts.jl` — stockout-aware demand cleaning and forecast preview.
- `src/planning/scenarios.jl` — deterministic seeded scenario generation and scenario persistence.
- `src/planning/simulations.jl` — run create/list/detail/cancel lifecycle service and status transitions.
- `src/jobs/locks.jl` — advisory lock helper for simulation worker claims.
- `src/jobs/worker.jl` — continuous simulation worker/reaper wiring.
- `src/web/controllers/simulation_controller.jl` — HTTP handlers for simulation run endpoints.
- `config/routes.jl` — production route registration for `/api/simulations` endpoints.
- `tests/unit/api/test_batch019_simulation_forecast.jl` — lifecycle, reproducibility, forecast, scenario, authz, and wiring coverage.
- `tests/e2e/tenant-admin-api.spec.js` — real HTTP fail-closed smoke for simulation endpoints.

## When to read this

Before writing any code that:
- Creates, claims, completes, fails, cancels, lists, or renders simulation runs.
- Generates demand scenarios or changes forecast preview semantics.
- Adds solver/recommendation outputs that consume `simulation_runs.input_snapshot` or `demand_scenarios.demand_payload`.
- Changes worker locks, stale-run reaping, or run idempotency behavior.

## Contract

- `create_simulation_run!` is the only run creation entrypoint; it authorizes `simulation:run_cancel`, captures `input_snapshot`, and stores `queued` runs.
- Completed run detail must read `simulation_runs.input_snapshot` and stored `demand_scenarios`; it must not reread mutable warehouses, SKUs, inventory, lanes, policies, or demand history to explain that run.
- Stockout periods use `demand_units + lost_sales_units` for cleaned demand and inflate uncertainty; zero observed sales with lost sales is not low demand.
- `generate_demand_scenarios!` uses caller-provided deterministic seeds and persists the full scenario payload for replay.
- Workers claim queued runs through advisory locking, transition to `running`, persist scenarios, then transition to `completed` or `failed`.
- `stale_run_reaper` marks old `running` runs `failed` with an explanatory `error_message` after the configured timeout.
- Route handlers remain thin: rate-limit, resolve tenant context, call lifecycle service, and return shared API envelopes.

## Cross-references

- PRD §5.3 Demand Forecast Module
- PRD §5.5 Simulation Run Module
- PRD §7 Scheduler / Background Jobs
- PRD §8b API Endpoints
- `.agent/knowledge/foundation/api-request-foundation.md`
- `.agent/knowledge/foundation/db-tenant-scoped-queries.md`
