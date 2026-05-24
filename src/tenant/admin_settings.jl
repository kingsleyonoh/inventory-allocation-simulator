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
