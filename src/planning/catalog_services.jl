function list_warehouses(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["region", "status"]))
    rows = fetch_warehouses(store, ctx.tenant_id, page)
    return _page_response(:warehouses, [_warehouse_response(row) for row in rows], page)
end

function get_warehouse(store::AbstractTenantAdminStore, ctx::TenantContext, warehouse_id)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = fetch_warehouse(store, ctx.tenant_id, _uuid_value(warehouse_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Warehouse not found"; status = 404))
    return _warehouse_response(row)
end

function create_warehouse!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    row = _warehouse_payload(ctx, payload)
    persist_warehouse_create!(store, row)
    return _warehouse_response(row)
end

function update_warehouse!(store::AbstractTenantAdminStore, ctx::TenantContext, warehouse_id, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    current = fetch_warehouse(store, ctx.tenant_id, _uuid_value(warehouse_id))
    current === nothing && throw(ApiError("NOT_FOUND", "Warehouse not found"; status = 404))
    row = _warehouse_payload(ctx, payload; current = current)
    persist_warehouse_update!(store, row)
    return _warehouse_response(row)
end

function deactivate_warehouse!(store::AbstractTenantAdminStore, ctx::TenantContext, warehouse_id)::NamedTuple
    return update_warehouse!(store, ctx, warehouse_id, Dict("active" => false))
end

function list_skus(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["category", "status"]))
    rows = fetch_skus(store, ctx.tenant_id, page)
    return _page_response(:skus, [_sku_response(row) for row in rows], page)
end

function get_sku(store::AbstractTenantAdminStore, ctx::TenantContext, sku_id)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = fetch_sku(store, ctx.tenant_id, _uuid_value(sku_id))
    row === nothing && throw(ApiError("NOT_FOUND", "SKU not found"; status = 404))
    return _sku_response(row)
end

function create_sku!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    row = _sku_payload(ctx, payload)
    persist_sku_create!(store, row)
    return _sku_response(row)
end

function update_sku!(store::AbstractTenantAdminStore, ctx::TenantContext, sku_id, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    current = fetch_sku(store, ctx.tenant_id, _uuid_value(sku_id))
    current === nothing && throw(ApiError("NOT_FOUND", "SKU not found"; status = 404))
    row = _sku_payload(ctx, payload; current = current)
    persist_sku_update!(store, row)
    return _sku_response(row)
end

function deactivate_sku!(store::AbstractTenantAdminStore, ctx::TenantContext, sku_id)::NamedTuple
    return update_sku!(store, ctx, sku_id, Dict("active" => false))
end

function list_inventory_positions(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["warehouse_id", "sku_id"]))
    rows = fetch_inventory_positions(store, ctx.tenant_id, page)
    return _page_response(:inventory, [_inventory_response(row) for row in rows], page)
end

function update_inventory_position!(store::AbstractTenantAdminStore, ctx::TenantContext, inventory_id, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    current = fetch_inventory_position(store, ctx.tenant_id, _uuid_value(inventory_id))
    current === nothing && throw(ApiError("NOT_FOUND", "Inventory position not found"; status = 404))
    row = merge_inventory_position(current, payload)
    persist_inventory_position_update!(store, row)
    return _inventory_response(row)
end

function merge_inventory_position(current, payload)::Dict{Symbol,Any}
    row = Dict{Symbol,Any}(current)
    for key in ("on_hand_units", "reserved_units", "inbound_units", "safety_stock_units")
        value = _optional_decimal(payload, key, row[Symbol(key)])
        _validate_nonnegative(key, value)
        row[Symbol(key)] = Float64(value)
    end
    source = _optional_text(payload, "source")
    source !== nothing && (row[:source] = _validate_choice("source", source, INVENTORY_SOURCES))
    return row
end

function list_demand_history(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["warehouse_id", "sku_id"]))
    rows = fetch_demand_history(store, ctx.tenant_id, page)
    return _page_response(:demand_history, [_demand_response(row) for row in rows], page)
end

function list_transfer_lanes(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["warehouse_id", "status"]))
    rows = fetch_transfer_lanes(store, ctx.tenant_id, page)
    return _page_response(:lanes, [_lane_response(row) for row in rows], page)
end

function create_transfer_lane!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    row = _lane_payload(store, ctx, payload)
    persist_transfer_lane_create!(store, row)
    return _lane_response(row)
end

function update_transfer_lane!(store::AbstractTenantAdminStore, ctx::TenantContext, lane_id, payload)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    current = fetch_transfer_lane(store, ctx.tenant_id, _uuid_value(lane_id))
    current === nothing && throw(ApiError("NOT_FOUND", "Transfer lane not found"; status = 404))
    row = _lane_payload(store, ctx, payload; current = current)
    persist_transfer_lane_update!(store, row)
    return _lane_response(row)
end

function deactivate_transfer_lane!(store::AbstractTenantAdminStore, ctx::TenantContext, lane_id)::NamedTuple
    return update_transfer_lane!(store, ctx, lane_id, Dict("active" => false))
end

function list_allocation_policies(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["status"]))
    rows = fetch_allocation_policies(store, ctx.tenant_id, page)
    return _page_response(:policies, [_policy_response(row) for row in rows], page)
end

function create_allocation_policy!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    authorize!(ctx, "manage", "policy")
    row = _policy_payload(ctx, payload)
    persist_allocation_policy_create!(store, row)
    return _policy_response(row)
end

function update_allocation_policy!(store::AbstractTenantAdminStore, ctx::TenantContext, policy_id, payload)::NamedTuple
    authorize!(ctx, "manage", "policy")
    current = fetch_allocation_policy(store, ctx.tenant_id, _uuid_value(policy_id))
    current === nothing && throw(ApiError("NOT_FOUND", "Allocation policy not found"; status = 404))
    row = _policy_payload(ctx, payload; current = current)
    persist_allocation_policy_update!(store, row)
    return _policy_response(row)
end

function archive_allocation_policy!(store::AbstractTenantAdminStore, ctx::TenantContext, policy_id)::NamedTuple
    return update_allocation_policy!(store, ctx, policy_id, Dict("status" => "archived"))
end
