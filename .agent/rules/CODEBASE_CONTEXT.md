# Inventory Allocation Simulator — Codebase Context

Last updated: 2026-05-23
Template synced: 2026-05-23
PRD: `docs/inventory-allocation-simulator_prd.md`

## Project Summary
Multi-tenant Julia/Genie supply-chain planning system. It imports warehouse, SKU, inventory, demand, lane, and policy data; simulates demand scenarios; solves allocation recommendations with JuMP/HiGHS; and explains tradeoffs. CSV/local operation is mandatory; ecosystem adapters are optional.

## Tech Stack
| Layer | Technology |
|---|---|
| Language | Julia 1.11 |
| Web/API | Genie.jl server-rendered views + HTTP APIs |
| Optimization | JuMP + HiGHS |
| Forecasting | StatsBase, Distributions, custom exponential smoothing |
| Database | PostgreSQL 16 |
| Analytics | DuckDB embedded |
| Cache/Jobs | Redis 7 + Julia task workers + persisted `jobs` tables |
| Frontend | Genie views, HTMX, Tailwind |
| Tests | Julia `Test`, Aqua.jl, HTTP.jl integration, Playwright smoke tests |
| Hosting | Docker Compose, GHCR image, Hetzner/DigitalOcean VPS |
| Observability | JSON logs, Prometheus `/metrics`, Sentry-compatible webhook |

## Commands
| Purpose | Command |
|---|---|
| Install Julia deps | `julia --project -e 'using Pkg; Pkg.instantiate()'` |
| Start app | `julia --project src/Main.jl` |
| Run tests | `julia --project -e 'using Pkg; Pkg.test()'` |
| Run tests (unit only) | `julia --project -e 'using Pkg; Pkg.test(test_args=["unit"])'` |
| Run tests (integration only) | `julia --project -e 'using Pkg; Pkg.test(test_args=["integration"])'` |
| Lint/static checks | `julia --project -e 'using Aqua, InventoryAllocationSimulator; Aqua.test_all(InventoryAllocationSimulator; stale_deps=false)'` |
| E2E tests | `npx playwright test` |
| Start infra | `docker compose up -d postgres redis` |
| Stop infra | `docker compose down` |
| Check infra | `docker compose ps` |
| Migrate | `julia --project scripts/migrate.jl up` |
| First-run setup | `julia --project scripts/setup.jl` |
| Secret scan | `bash scripts/scan-secrets.sh` |

## Project Structure
| Path | Purpose |
|---|---|
| `src/Main.jl` | Genie entrypoint |
| `config/` | Routes and app configuration |
| `src/db/` | Connection, migrations, scoped query helpers |
| `src/tenant/` | Tenant context, API-key/session auth, authorization registry |
| `src/imports/` | CSV parser, validators, import worker logic |
| `src/planning/` | Forecasts, scenarios, snapshots, backtests |
| `src/solver/` | JuMP model, objectives, constraints, explanations |
| `src/recommendations/` | Recommendation service, decisions, exports |
| `src/notifications/` | Local notifications and event normalization |
| `src/jobs/` | Workers, locks, import/simulation/outbox/reaper jobs |
| `src/integrations/` | Optional Notification Hub, Workflow Engine, Delivery Gateway adapters |
| `src/events/` | Event envelope utilities |
| `src/web/` | Controllers, views, HTMX components |
| `src/observability/` | Logging, metrics, error reporting |
| `migrations/` | PostgreSQL migrations |
| `tests/` | Unit, integration, E2E, fixtures |

## Shared Foundation
| Foundation | Planned path | Establishes |
|---|---|---|
| DB connection | `src/db/connection.jl` | PostgreSQL pool lifecycle and query entrypoint |
| Scoped queries | `src/db/scoped_queries.jl` | Tenant-enforced query helpers |
| Tenant context | `src/tenant/context.jl` | Request/job tenant and user context |
| Auth | `src/tenant/auth.jl` | API-key/session resolution |
| Authorization | `src/tenant/authz.jl` | Role-resource matrix and `authorize!` |
| Jobs locks | `src/jobs/locks.jl` | Advisory locks and worker claim safety |
| Event envelope | `src/events/envelope.jl` | Stable ecosystem event shape |
| HTTP integrations | `src/integrations/http_client.jl` | Retries, timeouts, auth headers |
| Observability | `src/observability/` | JSON logging, request IDs, metrics, errors |

## Deep References
| Module | Path |
|---|---|
| Tenant/Auth | `src/tenant/` |
| Imports | `src/imports/` |
| Forecasting/Planning | `src/planning/` |
| Solver | `src/solver/` |
| Recommendations | `src/recommendations/` |
| Local notifications | `src/notifications/` |
| Background jobs | `src/jobs/` |
| Ecosystem adapters | `src/integrations/` |
| Web console | `src/web/` |
| Observability | `src/observability/` |

## Data Model Overview
Primary tables: `tenants`, `users`, `warehouses`, `skus`, `inventory_positions`, `demand_history`, `transfer_lanes`, `allocation_policies`, `simulation_runs`, `demand_scenarios`, `allocation_recommendations`, `recommendation_decisions`, `import_jobs`, `ecosystem_outbox`, `local_notifications`. Every data-bearing table is tenant-scoped.

## Tenant Model
API requests use `X-API-Key`; UI uses signed session cookies. Tenant context must exist before querying data. Roles are `admin`, `planner`, `viewer`; permissions are seeded in `tests/fixtures/authz_matrix.json` and enforced through `authorize!(ctx, action, resource)`.

## Environment Variables
See `.env.example`. Critical services: `DATABASE_URL`, `REDIS_URL`, `DUCKDB_PATH`, `SESSION_SECRET`, solver/import config, adapter URLs/API keys, `METRICS_TOKEN`.

## External Integrations
| Integration | Mode | Notes |
|---|---|---|
| CSV import/export | Required local adapter | Fixture CSVs in `tests/fixtures/csv/` |
| Delivery Tracking Gateway | Optional receive | REST or Redis stream freshness; must not block core |
| Notification Hub | Optional send | `POST /api/events`; local notifications remain canonical fallback |
| Workflow Automation Engine | Optional send | `POST /api/workflows/{workflow_id}/execute` |
| Prometheus | Metrics | `/metrics` protected by internal token |
| Sentry-compatible webhook | Optional errors | Local error table fallback acceptable |

## Key Patterns & Conventions
- Freeze simulation input snapshots and use them for every report/export of that run.
- Use one shared net-value calculation path for API, UI, CSV, and notification payloads.
- Optional ecosystem adapter failure cannot mutate core recommendation truth.
- Missing authorization policy keys fail closed with 403 and audit logging.
- Stockout periods inflate uncertainty; they are not evidence of low demand.

## Known Gotchas
| Gotcha | Mitigation |
|---|---|
| Julia package/test commands differ from Node/Python defaults | Use the Commands table above; do not assume `julia --project -e 'using Pkg; Pkg.test()'`/`pytest`. |
| Optional adapters can accidentally become hard dependencies | Keep feature flags off by default and never block `/health/ready` on disabled adapters. |
| Tenant identity in exports/notifications is easy to hardcode | Read tenant identity columns from DB via payload builders. |
