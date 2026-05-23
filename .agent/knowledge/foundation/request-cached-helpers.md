# Request Cached Helpers

## What it establishes

Request-scoped expensive lookups use one `RequestCache` and `get_cached!` so each per tenant request computes tenant, authorization, summary, or adapter status facts once instead of multiplying work across handlers.

## Files

- `src/cache/request_cache.jl` — lightweight request cache primitive
- `src/InventoryAllocationSimulator.jl` — includes and exports the primitive
- `tests/unit/setup/test_batch004_contracts.jl` — memoization and failure behavior coverage

## When to read this

Before writing any code that:
- Reuses tenant, user, authorization, dashboard summary, run metrics, or adapter status data within one request
- Adds a route, UI controller, worker claim path, or integration dispatcher that has 2+ consumers of the same expensive lookup
- Adds a new cache with request lifetime rather than process or Redis lifetime

## Contract

- Create one `RequestCache` per tenant request, job claim, or dispatch cycle; never share it globally across tenants.
- Use `get_cached!(cache, key) do ... end` for deterministic, idempotent lookups only.
- Cache keys must include the resource concept and tenant-specific scope when a cache can hold multiple tenants in one process.
- Loader exceptions are not cached; callers should see the real failure and a retry should rerun the loader.
- Do not use request cache as authorization storage. The source of truth remains `authorize!(ctx, action, resource)` and the authz matrix fixture.

## Cross-references

- PRD §7 Shared utilities
- PRD §10b Caching Strategy
- `.agent/rules/CODING_STANDARDS_DOMAIN.md` Server-Side Performance Rules
