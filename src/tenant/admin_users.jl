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
    parsed_id = _tenant_admin_uuid_value(user_id)
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
