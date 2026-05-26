# Performance Benchmark Fixtures

## What it establishes

PRD §10b performance targets and benchmark-scale fixture dimensions are centralized in exported Julia helpers so scripts, tests, and future CI jobs use the same p95 thresholds and data sizes.

## Files

- `src/performance/benchmark_fixtures.jl` — target constants and benchmark fixture builders.
- `scripts/benchmarks/run_performance_benchmarks.jl` — JSON manifest runner for benchmark fixtures, executable p95 timings, solver-timeout budget, and outbox dispatch latency.
- `tests/unit/setup/test_batch040_performance_benchmarks.jl` — target, fixture-size, unhappy-path, script, and E2E wiring contracts.
- `tests/e2e/dashboard-lcp-benchmark.spec.js` — opt-in browser LCP benchmark for operations console pages.
- `tests/e2e/postgres-redis-stack.spec.js` — running-server PostgreSQL/Redis E2E stack proof.

## When to read this

Before writing any code that:
- Adds, changes, or consumes a PRD §10b performance target.
- Creates benchmark fixtures for simulations, recommendations, CSV imports, or operations-console pages.
- Adds CI or deployment gates that execute performance benchmarks.
- Changes dashboard page LCP measurement or benchmark page selection.

## Contract

- Use `performance_targets()` as the source of truth for PRD §10b target values, including solver timeout grace and outbox dispatch latency.
- The large simulation fixture defaults to exactly 50 warehouses, 2,000 SKUs, and 100 scenarios.
- Recommendation list benchmarks default to exactly 10,000 tenant-scoped proposed recommendations.
- CSV import benchmarks default to exactly 100,000 inventory rows with production import headers.
- Dashboard LCP benchmark pages are declared by `dashboard_lcp_benchmark_pages()`; the Playwright LCP spec enforces the 2.5s target only when `RUN_PERF_BENCHMARKS=true` so ordinary smoke E2E remains stable.
- Solver timeout benchmarks must time `solve_allocation_model` with `AllocationSolverConfig` and assert the wall-clock budget is configured timeout plus `solver_timeout_grace_seconds`.
- Outbox dispatch latency benchmarks must drain queued `ecosystem_outbox` events through `benchmark_outbox_dispatch_60s!`/`dispatch_outbox_once!` and compare p95 against `outbox_dispatch_p95_ms`.
- Invalid benchmark dimensions must throw `ArgumentError`; do not silently coerce zero or negative sizes.

## Cross-references

- PRD §10b Performance & Observability.
- PRD §15 Success Criteria.
- `.agent/knowledge/foundation/observability-endpoints-events.md`.
