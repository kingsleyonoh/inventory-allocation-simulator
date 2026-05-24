function register_tenant!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    payload;
    key_material = nothing,
)::NamedTuple
    config.tenant.self_registration_enabled || throw(ApiError("FORBIDDEN", "Self-registration is disabled"; status = 403))
    name = _required_text(payload, "name")
    raw_key = generate_api_key(config.tenant.api_key_prefix; key_material = key_material)
    tenant_id = uuid4()
    insert_registered_tenant!(store, tenant_id, name, hash_api_key(raw_key))
    return (id = tenant_id, name = name, apiKey = raw_key)
end

function rotate_api_key!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    ctx::TenantContext;
    key_material = nothing,
)::NamedTuple
    authorize!(ctx, "manage", "user_api_key")
    raw_key = generate_api_key(config.tenant.api_key_prefix; key_material = key_material)
    persist_api_key_hash!(store, ctx.tenant_id, hash_api_key(raw_key))
    return (tenant_id = string(ctx.tenant_id), apiKey = raw_key, apiKeyHash = nothing)
end

function insert_registered_tenant!(store::MemoryTenantAdminStore, tenant_id::UUID, name::String, api_key_hash::String)
    store.tenants[tenant_id] = Dict{Symbol,Any}(
        :id => tenant_id,
        :name => name,
        :legal_name => name,
        :full_legal_name => name,
        :display_name => name,
        :address => Dict{String,Any}(),
        :registration => Dict{String,Any}(),
        :contact => Dict{String,Any}(),
        :wordmark => nothing,
        :api_key_hash => api_key_hash,
        :is_active => true,
    )
    return tenant_id
end

function insert_registered_tenant!(store::SqlTenantAdminStore, tenant_id::UUID, name::String, api_key_hash::String)
    LibPQ.execute(store.connection, """
        INSERT INTO tenants (id, name, legal_name, full_legal_name, display_name, api_key_hash)
        VALUES (\$1, \$2, \$2, \$2, \$2, \$3)
    """, [string(tenant_id), name, api_key_hash])
    return tenant_id
end

function persist_api_key_hash!(store::MemoryTenantAdminStore, tenant_id::UUID, api_key_hash::String)
    tenant = get(store.tenants, tenant_id, nothing)
    tenant === nothing && throw(ApiError("NOT_FOUND", "Tenant not found"; status = 404))
    tenant[:api_key_hash] = api_key_hash
    return tenant
end

function persist_api_key_hash!(store::SqlTenantAdminStore, tenant_id::UUID, api_key_hash::String)
    result = LibPQ.execute(store.connection, """
        UPDATE tenants SET api_key_hash = \$2, updated_at = now() WHERE id = \$1 AND is_active = true
    """, [string(tenant_id), api_key_hash])
    return result
end
