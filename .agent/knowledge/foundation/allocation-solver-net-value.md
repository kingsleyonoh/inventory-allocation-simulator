# Allocation Solver and Net Value Foundation

## What it establishes

Allocation solving uses one JuMP/HiGHS path for transfer constraints and one shared net-value calculation for recommendation outputs.

## Files

- `src/solver/model_builder.jl` — allocation model construction, objective selection, timeout/gap diagnostics, recommendation explanation JSON, persistence helpers, and `recommendation_net_value`.
- `src/planning/simulations.jl` — simulation worker calls demand scenario generation and then allocation recommendation generation before completing runs.
- `src/InventoryAllocationSimulator.jl` — exports solver primitives for future recommendation API/UI/export consumers.
- `tests/unit/api/test_batch020_forecast_solver.jl` — stockout correctness, solver constraints/objectives/diagnostics, net-value, confidence, and explanation coverage.

## When to read this

Before writing any code that:
- Builds or changes allocation recommendations.
- Displays, exports, notifies, or workflows recommendation net value or confidence.
- Adds recommendation APIs, UI view models, CSV exports, notification payloads, or workflow payloads.
- Changes simulation-worker behavior after demand scenarios are generated.

## Contract

- Use `recommendation_net_value` as the single source of truth for net value. Do not independently recompute net value in API, UI, CSV, notifications, or workflows.
- Solver outputs must include explanation JSON with `binding_constraints`, `scenario_sensitivity`, `accepted_tradeoffs`, `net_value`, and solver diagnostics.
- Solver infeasibility and timeout failures return readable diagnostics; timeout incumbents are accepted only when `solver_outcome_decision` sees a gap at or below `max_gap`.
- Tiny transfers below `AllocationSolverConfig.min_transfer_units` are suppressed instead of stored as recommendations.
- `generate_allocation_recommendations!` is idempotent per simulation run and is the worker-facing persistence entrypoint.

## Cross-references

- PRD §5.4 Allocation Solver Module
- PRD §15 Success Criteria
- `.agent/knowledge/foundation/simulation-lifecycle.md`
