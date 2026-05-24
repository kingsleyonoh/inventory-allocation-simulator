function fetch_warehouses(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.warehouses) if row[:tenant_id] == tenant_id]
    if haskey(page.filters, "region")
        rows = [row for row in rows if row[:region] == page.filters["region"]]
    end
    if haskey(page.filters, "status")
        active = _active_filter(page.filters["status"])
        rows = [row for row in rows if row[:active] == active]
    end
    return first(sort(rows; by = row -> row[:code]), min(page.limit, length(rows)))
end

function fetch_warehouse(store::MemoryTenantAdminStore, tenant_id::UUID, warehouse_id::UUID)
    row = get(store.warehouses, warehouse_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function persist_warehouse_create!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:code] == row[:code], values(store.warehouses))
        throw(ApiError("CONFLICT", "Warehouse code already exists for tenant"; status = 409))
    end
    store.warehouses[row[:id]] = row
    return row
end

function persist_warehouse_update!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:code] == row[:code] && existing[:id] != row[:id], values(store.warehouses))
        throw(ApiError("CONFLICT", "Warehouse code already exists for tenant"; status = 409))
    end
    store.warehouses[row[:id]] = row
    return row
end

function fetch_skus(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.skus) if row[:tenant_id] == tenant_id]
    if haskey(page.filters, "category")
        rows = [row for row in rows if row[:category] == page.filters["category"]]
    end
    if haskey(page.filters, "status")
        active = _active_filter(page.filters["status"])
        rows = [row for row in rows if row[:active] == active]
    end
    return first(sort(rows; by = row -> row[:sku_code]), min(page.limit, length(rows)))
end

function fetch_sku(store::MemoryTenantAdminStore, tenant_id::UUID, sku_id::UUID)
    row = get(store.skus, sku_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function persist_sku_create!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:sku_code] == row[:sku_code], values(store.skus))
        throw(ApiError("CONFLICT", "SKU code already exists for tenant"; status = 409))
    end
    store.skus[row[:id]] = row
    return row
end

function persist_sku_update!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:sku_code] == row[:sku_code] && existing[:id] != row[:id], values(store.skus))
        throw(ApiError("CONFLICT", "SKU code already exists for tenant"; status = 409))
    end
    store.skus[row[:id]] = row
    return row
end

function fetch_inventory_positions(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.inventory_positions) if row[:tenant_id] == tenant_id]
    rows = [row for row in rows if _matches_uuid_filter(row, page, "warehouse_id", :warehouse_id) && _matches_uuid_filter(row, page, "sku_id", :sku_id)]
    return first(sort(rows; by = row -> (row[:warehouse_id], row[:sku_id])), min(page.limit, length(rows)))
end

function fetch_inventory_position(store::MemoryTenantAdminStore, tenant_id::UUID, inventory_id::UUID)
    row = get(store.inventory_positions, inventory_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function persist_inventory_position_update!(store::MemoryTenantAdminStore, row)
    store.inventory_positions[row[:id]] = row
    return row
end

function fetch_demand_history(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.demand_history) if row[:tenant_id] == tenant_id]
    rows = [row for row in rows if _matches_uuid_filter(row, page, "warehouse_id", :warehouse_id) && _matches_uuid_filter(row, page, "sku_id", :sku_id)]
    return first(sort(rows; by = row -> (row[:period_start], row[:warehouse_id], row[:sku_id])), min(page.limit, length(rows)))
end

function fetch_transfer_lanes(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.transfer_lanes) if row[:tenant_id] == tenant_id]
    if haskey(page.filters, "warehouse_id")
        warehouse_id = _uuid_value(page.filters["warehouse_id"])
        rows = [row for row in rows if row[:from_warehouse_id] == warehouse_id || row[:to_warehouse_id] == warehouse_id]
    end
    if haskey(page.filters, "status")
        active = _active_filter(page.filters["status"])
        rows = [row for row in rows if row[:active] == active]
    end
    return first(sort(rows; by = row -> (row[:from_warehouse_id], row[:to_warehouse_id])), min(page.limit, length(rows)))
end

function persist_transfer_lane_create!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:from_warehouse_id] == row[:from_warehouse_id] && existing[:to_warehouse_id] == row[:to_warehouse_id], values(store.transfer_lanes))
        throw(ApiError("CONFLICT", "Transfer lane already exists for tenant"; status = 409))
    end
    store.transfer_lanes[row[:id]] = row
    return row
end

function fetch_allocation_policies(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.allocation_policies) if row[:tenant_id] == tenant_id]
    if haskey(page.filters, "status")
        status = _validate_choice("status", page.filters["status"], POLICY_STATUSES)
        rows = [row for row in rows if row[:status] == status]
    end
    return first(sort(rows; by = row -> row[:name]), min(page.limit, length(rows)))
end

function persist_allocation_policy_create!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:name] == row[:name], values(store.allocation_policies))
        throw(ApiError("CONFLICT", "Allocation policy name already exists for tenant"; status = 409))
    end
    store.allocation_policies[row[:id]] = row
    return row
end
