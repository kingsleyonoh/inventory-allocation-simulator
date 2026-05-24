# Tenant Admin Authorization API

## What it establishes

Tenant administration APIs resolve tenant context, enforce the PRD role/resource matrix through `authorize!(ctx, action, resource)`, and fail closed before tenant settings or user records are read or mutated.

## Files

- `config/authz_matrix.json` — runtime-copied authorization matrix derived from PRD §2b
- `src/tenant/authz.jl` — authorization registry seeded from the runtime matrix, fail-closed `authorize!`, and 403 error mapping
- `src/tenant/admin_api.jl` — tenant registration, tenant profile/settings, and user list/create/update store/service functions
- `src/web/controllers/tenant_admin_controller.jl` — Genie HTTP handlers for tenant/admin API endpoints
- `config/routes.jl` — production route registration for tenant profile, settings, registration, and user endpoints
- `tests/unit/api/test_tenant_admin_api.jl` — matrix, self-registration guard, tenant-scope, and admin authorization coverage
- `tests/e2e/tenant-admin-api.spec.js` — real HTTP wiring smoke for protected fail-closed routes and disabled self-registration

## When to read this

Before writing any code that:
- Adds or changes a protected API/UI/job action that needs role/resource authorization
- Extends the authorization matrix fixture or introduces a new `{resource}:{action}` policy key
- Reads or mutates tenant profile/settings fields
- Lists, creates, updates, deactivates, invites, or otherwise manages tenant users or API keys
- Adds route handlers that depend on API-key/session tenant context

## Contract

- Authorization source of truth is the runtime-copied `config/authz_matrix.json` (kept in parity with `tests/fixtures/authz_matrix.json`); consumers call `authorize!(ctx, action, resource)` and must not duplicate role checks inline.
- Missing policy keys and explicit deny cells throw `AuthzError` with HTTP 403. New policy keys must be added to the fixture before routes use them.
- Tenant settings reads use `tenant_settings:read`; tenant settings writes use `tenant_settings:write`; user/API-key management uses `user_api_key:manage`.
- Store operations receive a resolved `TenantContext` before data access and always scope tenant/user records by `ctx.tenant_id`.
- `POST /api/tenants/register` honors `SELF_REGISTRATION_ENABLED` before opening a database connection and returns one-time raw API keys only from the registration path.
- Protected HTTP handlers apply `default_rate_limit_policy`/`check_rate_limit!` before tenant data access and return the shared PRD §8b error envelope for rate-limited, unauthenticated, unauthorized, validation, not-found, and conflict cases.
- SQL-backed session authentication reads `user_sessions` joined to tenant-scoped users and tenants; inactive tenants/users, revoked sessions, and expired sessions fail closed.

## Cross-references

- PRD §2b Roles × Resource Actions
- PRD §5.1 Tenant and Auth Module
- PRD §8b API Endpoints
- `.agent/knowledge/foundation/api-request-foundation.md`
- `.agent/knowledge/foundation/db-tenant-scoped-queries.md`
