# DB Tenant-Scoped Queries

## What it establishes

Tenant-scoped data access starts from a resolved `TenantContext`, includes an explicit `tenant_id` predicate, and prefers join-first SQL for related planning records.

## Files

- `src/tenant/context.jl` — `TenantContext`, required-context guard, tenant cache keys, and tenant row filtering
- `src/db/scoped_queries.jl` — tenant WHERE clause builder, scoped SELECT builder, tenant-scope assertion, and join-first inventory query shape
- `src/InventoryAllocationSimulator.jl` — includes and exports the primitives
- `tests/unit/data/test_tenant_scoped_queries.jl` — tenant filter, unsafe identifier, cross-tenant row, and join-first coverage

## When to read this

Before writing any code that:
- Reads or writes a tenant-scoped database table
- Adds a repository or query helper under `src/db/`, `src/imports/`, `src/planning/`, or API handlers
- Joins planning records such as inventory, warehouses, SKUs, lanes, runs, or recommendations
- Adds cross-tenant isolation tests for repositories, jobs, endpoints, exports, or notifications

## Contract

- Every data access path must receive a non-null `TenantContext` before SQL or row filtering happens.
- SQL helpers must include a tenant predicate (`tenant_id = $1` or an alias-qualified equivalent). `assert_tenant_scoped_sql` rejects unscoped SQL.
- Table and alias names are validated as identifiers before interpolation. Values remain parameterized and are not string-concatenated into SQL.
- Query helpers that need related records should use join-first shapes. For inventory lists, `inventory_positions_with_dimensions_sql` joins warehouses and SKUs in one query and scopes each join by tenant.
- Cross-tenant tests must include at least two tenants and assert Tenant A results do not include Tenant B literals.

## Cross-references

- PRD §2 Architecture Principles
- PRD §2b Coverage Matrices
- PRD §7 Shared utilities
- `.agent/rules/CODING_STANDARDS_DOMAIN.md` Prefer Joins Over Multiple Queries
