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
