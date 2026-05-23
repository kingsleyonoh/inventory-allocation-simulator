# API Request Foundation

## What it establishes

API request helpers share one error envelope, cursor pagination parser, in-memory rate-limit contract, and tenant-auth context resolver before endpoint-specific handlers perform business work.

## Files

- `src/web/errors.jl` — PRD §8b `{ error: { code, message, details } }` formatter and endpoint error mapping
- `src/web/pagination.jl` — cursor pagination and filter validation primitive for list endpoints
- `src/web/rate_limit.jl` — request/action quota policy and per-identity in-memory limiter primitive
- `src/tenant/auth.jl` — API-key/session tenant context resolution through store abstractions and request cache
- `src/tenant/context.jl` — tenant context value and row-scope helpers
- `src/InventoryAllocationSimulator.jl` — includes and exports the primitives
- `tests/unit/api/test_foundation_api_contracts.jl` — API error, pagination, rate-limit, auth, and request-cache coverage

## When to read this

Before writing any code that:
- Adds an API route, UI-protected route, middleware, or endpoint handler
- Parses list filters, cursor/limit parameters, or endpoint action quotas
- Resolves `X-API-Key` or signed session cookies to tenant/user context
- Handles endpoint errors returned to API clients

## Contract

- API clients always receive `format_error_response(code, message; details)` shape: `{ "error": { "code", "message", "details" } }`.
- Unexpected server errors are formatted as `INTERNAL_ERROR` and must not expose stack traces, file paths, key material, or SQL internals.
- List endpoints parse pagination through `parse_cursor_params`; default page size is 25, max is 250, and unsupported filters raise `ApiError("VALIDATION_ERROR", ...)`.
- Rate-limit checks are per identity plus route/action policy. Endpoint batches should call `default_rate_limit_policy(method, path)` or define a stricter `RateLimitPolicy` from the PRD endpoint table.
- API-key auth hashes raw keys with `hash_api_key` and only looks up active tenants by hash. Raw keys are never stored or logged.
- Session auth accepts signed cookies through `signed_session_cookie`/`verify_session_cookie`; expired or inactive sessions fail closed.
- Request handlers create one `RequestCache` per request and call `resolve_tenant_context(...; cache)` so repeated tenant resolution is computed once.

## Cross-references

- PRD §5.1 Tenant and Auth Module
- PRD §8b API Endpoints
- `.agent/knowledge/foundation/request-cached-helpers.md`
