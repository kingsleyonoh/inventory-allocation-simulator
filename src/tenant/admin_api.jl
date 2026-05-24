using Dates
using JSON3
using LibPQ
using UUIDs

abstract type AbstractTenantAdminStore <: AbstractAuthStore end

mutable struct MemoryTenantAdminStore <: AbstractTenantAdminStore
    tenants::Dict{UUID,Dict{Symbol,Any}}
    users::Dict{UUID,Dict{Symbol,Any}}
    warehouses::Dict{UUID,Dict{Symbol,Any}}
    skus::Dict{UUID,Dict{Symbol,Any}}
end

function _record_map(records::AbstractVector)::Dict{UUID,Dict{Symbol,Any}}
    mapped = Dict{UUID,Dict{Symbol,Any}}()
    for record in records
        mapped[record.id] = Dict{Symbol,Any}(name => getproperty(record, name) for name in propertynames(record))
    end
    return mapped
end

function MemoryTenantAdminStore(
    tenants::AbstractVector,
    users::AbstractVector;
    warehouses::AbstractVector = [],
    skus::AbstractVector = [],
)::MemoryTenantAdminStore
    return MemoryTenantAdminStore(_record_map(tenants), _record_map(users), _record_map(warehouses), _record_map(skus))
end

mutable struct SqlTenantAdminStore <: AbstractTenantAdminStore
    connection::LibPQ.Connection
end

function _payload_get(payload, key::AbstractString, default = nothing)
    sym = Symbol(key)
    if payload isa AbstractDict
        haskey(payload, key) && return payload[key]
        haskey(payload, sym) && return payload[sym]
        return default
    end
    sym in propertynames(payload) && return getproperty(payload, sym)
    return default
end

function _required_text(payload, key::AbstractString)::String
    value = _payload_get(payload, key, nothing)
    value === nothing && throw(ApiError("VALIDATION_ERROR", "$key is required"; status = 400))
    text = strip(String(value))
    isempty(text) && throw(ApiError("VALIDATION_ERROR", "$key is required"; status = 400))
    return text
end

function _optional_text(payload, key::AbstractString)::Union{Nothing,String}
    value = _payload_get(payload, key, nothing)
    value === nothing && return nothing
    text = strip(String(value))
    isempty(text) && throw(ApiError("VALIDATION_ERROR", "$key cannot be blank"; status = 400))
    return text
end

function _optional_bool(payload, key::AbstractString)::Union{Nothing,Bool}
    value = _payload_get(payload, key, nothing)
    value === nothing && return nothing
    value isa Bool && return value
    lowered = lowercase(strip(String(value)))
    lowered in ("true", "1", "yes") && return true
    lowered in ("false", "0", "no") && return false
    throw(ApiError("VALIDATION_ERROR", "$key must be true or false"; status = 400))
end

function _json_payload_value(payload, key::AbstractString, current)
    value = _payload_get(payload, key, nothing)
    value === nothing && return current
    return value
end

_is_nullish(value)::Bool = value === nothing || value === missing
_nullable_text(value)::Union{Nothing,String} = _is_nullish(value) ? nothing : String(value)

function _tenant_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        name = String(row[:name]),
        legal_name = String(row[:legal_name]),
        full_legal_name = String(row[:full_legal_name]),
        display_name = String(row[:display_name]),
        address = row[:address],
        registration = row[:registration],
        contact = row[:contact],
        wordmark = _nullable_text(row[:wordmark]),
    )
end

function _user_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        email = String(row[:email]),
        name = String(row[:name]),
        role = String(row[:role]),
        is_active = Bool(row[:is_active]),
    )
end

function _validate_role(role::AbstractString)::String
    value = strip(String(role))
    value in VALID_TENANT_ROLES || throw(ApiError("VALIDATION_ERROR", "role must be admin, planner, or viewer"; status = 400))
    return value
end

function lookup_tenant_by_api_key_hash(store::MemoryTenantAdminStore, api_key_hash::String)
    for tenant in values(store.tenants)
        tenant[:api_key_hash] == api_key_hash || continue
        return TenantAuthRecord(tenant[:id], nothing, "admin", Bool(tenant[:is_active]))
    end
    return nothing
end

lookup_session_record(::MemoryTenantAdminStore, _session_id::String) = nothing

function lookup_tenant_by_api_key_hash(store::SqlTenantAdminStore, api_key_hash::String)
    result = LibPQ.execute(store.connection, """
        SELECT id, is_active FROM tenants WHERE api_key_hash = \$1 LIMIT 1
    """, [api_key_hash])
    isempty(result) && return nothing
    row = first(result)
    return TenantAuthRecord(UUID(String(row[1])), nothing, "admin", Bool(row[2]))
end

function _sql_datetime(value)::DateTime
    value isa DateTime && return value
    return DateTime(replace(String(value), " " => "T"))
end

function lookup_session_record(store::SqlTenantAdminStore, session_id::String)
    result = LibPQ.execute(store.connection, """
        SELECT s.tenant_id, s.user_id, u.role,
               (u.is_active AND t.is_active AND s.revoked_at IS NULL) AS is_active,
               s.expires_at
        FROM user_sessions s
        JOIN users u ON u.id = s.user_id AND u.tenant_id = s.tenant_id
        JOIN tenants t ON t.id = s.tenant_id
        WHERE s.id = \$1
        LIMIT 1
    """, [session_id])
    isempty(result) && return nothing
    row = first(result)
    return SessionAuthRecord(
        UUID(String(row[1])),
        UUID(String(row[2])),
        String(row[3]),
        Bool(row[4]),
        _sql_datetime(row[5]),
    )
end

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

function get_tenant_profile(store::AbstractTenantAdminStore, ctx::TenantContext)::NamedTuple
    authorize!(ctx, "read", "tenant_settings")
    row = fetch_tenant_profile(store, ctx.tenant_id)
    row === nothing && throw(ApiError("NOT_FOUND", "Tenant not found"; status = 404))
    return _tenant_response(row)
end

fetch_tenant_profile(store::MemoryTenantAdminStore, tenant_id::UUID) = get(store.tenants, tenant_id, nothing)

function fetch_tenant_profile(store::SqlTenantAdminStore, tenant_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, name, legal_name, full_legal_name, display_name, address, registration, contact, wordmark
        FROM tenants WHERE id = \$1 AND is_active = true LIMIT 1
    """, [string(tenant_id)])
    isempty(result) && return nothing
    row = first(result)
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :name => row[2], :legal_name => row[3],
        :full_legal_name => row[4], :display_name => row[5], :address => JSON3.read(String(row[6])),
        :registration => JSON3.read(String(row[7])), :contact => JSON3.read(String(row[8])), :wordmark => row[9],
    )
end

function update_tenant_settings!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    authorize!(ctx, "write", "tenant_settings")
    current = fetch_tenant_profile(store, ctx.tenant_id)
    current === nothing && throw(ApiError("NOT_FOUND", "Tenant not found"; status = 404))
    updated = merge_tenant_settings(current, payload)
    persist_tenant_settings!(store, ctx.tenant_id, updated)
    return _tenant_response(updated)
end

function merge_tenant_settings(current, payload)::Dict{Symbol,Any}
    updated = Dict{Symbol,Any}(current)
    for key in ("name", "legal_name", "full_legal_name", "display_name", "wordmark")
        value = _optional_text(payload, key)
        value !== nothing && (updated[Symbol(key)] = value)
    end
    updated[:address] = _json_payload_value(payload, "address", updated[:address])
    updated[:registration] = _json_payload_value(payload, "registration", updated[:registration])
    updated[:contact] = _json_payload_value(payload, "contact", updated[:contact])
    return updated
end

function persist_tenant_settings!(store::MemoryTenantAdminStore, tenant_id::UUID, updated)
    store.tenants[tenant_id] = updated
    return updated
end

function persist_tenant_settings!(store::SqlTenantAdminStore, tenant_id::UUID, updated)
    LibPQ.execute(store.connection, """
        UPDATE tenants
        SET name = \$2, legal_name = \$3, full_legal_name = \$4, display_name = \$5,
            address = \$6::jsonb, registration = \$7::jsonb, contact = \$8::jsonb, wordmark = \$9,
            updated_at = now()
        WHERE id = \$1
    """, [string(tenant_id), updated[:name], updated[:legal_name], updated[:full_legal_name], updated[:display_name],
          JSON3.write(updated[:address]), JSON3.write(updated[:registration]), JSON3.write(updated[:contact]), updated[:wordmark]])
    return updated
end

function list_users(store::AbstractTenantAdminStore, ctx::TenantContext)::Vector{NamedTuple}
    authorize!(ctx, "manage", "user_api_key")
    return [_user_response(user) for user in fetch_users(store, ctx.tenant_id)]
end

function fetch_users(store::MemoryTenantAdminStore, tenant_id::UUID)
    return sort([user for user in values(store.users) if user[:tenant_id] == tenant_id]; by = user -> user[:email])
end

function fetch_users(store::SqlTenantAdminStore, tenant_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, email, name, role, is_active FROM users WHERE tenant_id = \$1 ORDER BY email
    """, [string(tenant_id)])
    return [_sql_user_row(row) for row in result]
end

function _sql_user_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :email => row[3],
        :name => row[4], :role => row[5], :is_active => Bool(row[6]),
    )
end

function create_user!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    authorize!(ctx, "manage", "user_api_key")
    user = Dict{Symbol,Any}(
        :id => uuid4(),
        :tenant_id => ctx.tenant_id,
        :email => lowercase(_required_text(payload, "email")),
        :name => _required_text(payload, "name"),
        :role => _validate_role(_required_text(payload, "role")),
        :is_active => something(_optional_bool(payload, "is_active"), true),
    )
    persist_user_create!(store, user)
    return _user_response(user)
end

function persist_user_create!(store::MemoryTenantAdminStore, user)
    if any(row -> row[:tenant_id] == user[:tenant_id] && row[:email] == user[:email], values(store.users))
        throw(ApiError("CONFLICT", "User email already exists for tenant"; status = 409))
    end
    store.users[user[:id]] = user
    return user
end

function persist_user_create!(store::SqlTenantAdminStore, user)
    try
        LibPQ.execute(store.connection, """
            INSERT INTO users (id, tenant_id, email, name, role, is_active)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6)
        """, [string(user[:id]), string(user[:tenant_id]), user[:email], user[:name], user[:role], user[:is_active]])
    catch err
        throw(ApiError("CONFLICT", "User email already exists for tenant"; status = 409))
    end
    return user
end

function update_user!(store::AbstractTenantAdminStore, ctx::TenantContext, user_id, payload)::NamedTuple
    authorize!(ctx, "manage", "user_api_key")
    parsed_id = user_id isa UUID ? user_id : UUID(String(user_id))
    current = fetch_user(store, ctx.tenant_id, parsed_id)
    current === nothing && throw(ApiError("NOT_FOUND", "User not found"; status = 404))
    role = _optional_text(payload, "role")
    active = _optional_bool(payload, "is_active")
    role !== nothing && (current[:role] = _validate_role(role))
    active !== nothing && (current[:is_active] = active)
    persist_user_update!(store, current)
    return _user_response(current)
end

function fetch_user(store::MemoryTenantAdminStore, tenant_id::UUID, user_id::UUID)
    user = get(store.users, user_id, nothing)
    user === nothing && return nothing
    return user[:tenant_id] == tenant_id ? user : nothing
end

function fetch_user(store::SqlTenantAdminStore, tenant_id::UUID, user_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, email, name, role, is_active FROM users WHERE tenant_id = \$1 AND id = \$2 LIMIT 1
    """, [string(tenant_id), string(user_id)])
    isempty(result) && return nothing
    return _sql_user_row(first(result))
end

function persist_user_update!(store::MemoryTenantAdminStore, user)
    store.users[user[:id]] = user
    return user
end

function persist_user_update!(store::SqlTenantAdminStore, user)
    LibPQ.execute(store.connection, """
        UPDATE users SET role = \$3, is_active = \$4, updated_at = now() WHERE tenant_id = \$1 AND id = \$2
    """, [string(user[:tenant_id]), string(user[:id]), user[:role], user[:is_active]])
    return user
end
