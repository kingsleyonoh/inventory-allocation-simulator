function _find_warehouse_by_code(store::MemoryTenantAdminStore, tenant_id::UUID, code::AbstractString)
    wanted = uppercase(strip(String(code)))
    for row in values(store.warehouses)
        row[:tenant_id] == tenant_id && uppercase(String(row[:code])) == wanted && return row
    end
    return nothing
end

function _find_sku_by_code(store::MemoryTenantAdminStore, tenant_id::UUID, code::AbstractString)
    wanted = uppercase(strip(String(code)))
    for row in values(store.skus)
        row[:tenant_id] == tenant_id && uppercase(String(row[:sku_code])) == wanted && return row
    end
    return nothing
end

function _find_warehouse_by_code(store::SqlTenantAdminStore, tenant_id::UUID, code::AbstractString)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, code, name, region, latitude, longitude, capacity_units, handling_cost_cents, active
        FROM warehouses
        WHERE tenant_id = \$1 AND upper(code) = \$2
        LIMIT 1
    """, [string(tenant_id), uppercase(strip(String(code)))])
    isempty(result) && return nothing
    return _sql_warehouse_row(first(result))
end

function _find_sku_by_code(store::SqlTenantAdminStore, tenant_id::UUID, code::AbstractString)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, sku_code, name, category, unit_volume, unit_margin_cents, stockout_cost_cents, holding_cost_cents, active
        FROM skus
        WHERE tenant_id = \$1 AND upper(sku_code) = \$2
        LIMIT 1
    """, [string(tenant_id), uppercase(strip(String(code)))])
    isempty(result) && return nothing
    return _sql_sku_row(first(result))
end
