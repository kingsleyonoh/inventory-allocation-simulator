using UUIDs

const VALID_TENANT_ROLES = Set(["admin", "planner", "viewer"])

struct TenantContext
    tenant_id::UUID
    user_id::Union{Nothing,UUID}
    role::String
    auth_method::Symbol
end

function TenantContext(
    tenant_id::Union{Nothing,UUID};
    user_id::Union{Nothing,UUID} = nothing,
    role::AbstractString = "viewer",
    auth_method::Symbol = :api_key,
)::TenantContext
    tenant_id === nothing && throw(ArgumentError("tenant context is required before data access"))
    role_string = String(role)
    role_string in VALID_TENANT_ROLES || throw(ArgumentError("role must be admin, planner, or viewer"))
    auth_method in (:api_key, :session, :job) || throw(ArgumentError("unsupported auth method"))
    return TenantContext(tenant_id, user_id, role_string, auth_method)
end

function require_tenant_context(ctx::Union{Nothing,TenantContext})::TenantContext
    ctx === nothing && throw(ArgumentError("tenant context is required before data access"))
    return ctx
end

function tenant_cache_key(ctx::TenantContext, concept::Symbol)::Symbol
    return Symbol(string(concept), ":", string(ctx.tenant_id))
end

function tenant_filter_records(ctx::TenantContext, rows)
    require_tenant_context(ctx)
    return [row for row in rows if getproperty(row, :tenant_id) == ctx.tenant_id]
end
