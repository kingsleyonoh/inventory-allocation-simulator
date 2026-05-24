function _sql_inventory_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :warehouse_id => UUID(String(row[3])),
        :sku_id => UUID(String(row[4])), :on_hand_units => row[5], :reserved_units => row[6],
        :inbound_units => row[7], :safety_stock_units => row[8], :as_of => row[9], :source => row[10],
    )
end

function fetch_inventory_positions(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    warehouse_filter = haskey(page.filters, "warehouse_id") ? string(_uuid_value(page.filters["warehouse_id"])) : nothing
    sku_filter = haskey(page.filters, "sku_id") ? string(_uuid_value(page.filters["sku_id"])) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, warehouse_id, sku_id, on_hand_units, reserved_units, inbound_units, safety_stock_units, as_of, source
        FROM inventory_positions
        WHERE tenant_id = \$1
          AND warehouse_id = COALESCE(\$2::uuid, warehouse_id)
          AND sku_id = COALESCE(\$3::uuid, sku_id)
        ORDER BY warehouse_id, sku_id
        LIMIT \$4
    """, [string(tenant_id), _sql_null(warehouse_filter), _sql_null(sku_filter), page.limit])
    return [_sql_inventory_row(row) for row in result]
end

function fetch_inventory_position(store::SqlTenantAdminStore, tenant_id::UUID, inventory_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, warehouse_id, sku_id, on_hand_units, reserved_units, inbound_units, safety_stock_units, as_of, source
        FROM inventory_positions
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(inventory_id)])
    isempty(result) && return nothing
    return _sql_inventory_row(first(result))
end

function persist_inventory_position_update!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        UPDATE inventory_positions
        SET on_hand_units = \$3, reserved_units = \$4, inbound_units = \$5, safety_stock_units = \$6,
            source = \$7, updated_at = now()
        WHERE tenant_id = \$1 AND id = \$2
    """, [string(row[:tenant_id]), string(row[:id]), row[:on_hand_units], row[:reserved_units], row[:inbound_units], row[:safety_stock_units], row[:source]])
    return row
end

function _sql_demand_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :warehouse_id => UUID(String(row[3])),
        :sku_id => UUID(String(row[4])), :period_start => row[5], :period_end => row[6],
        :demand_units => row[7], :lost_sales_units => row[8], :source => row[9],
    )
end

function fetch_demand_history(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    warehouse_filter = haskey(page.filters, "warehouse_id") ? string(_uuid_value(page.filters["warehouse_id"])) : nothing
    sku_filter = haskey(page.filters, "sku_id") ? string(_uuid_value(page.filters["sku_id"])) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, warehouse_id, sku_id, period_start, period_end, demand_units, lost_sales_units, source
        FROM demand_history
        WHERE tenant_id = \$1
          AND warehouse_id = COALESCE(\$2::uuid, warehouse_id)
          AND sku_id = COALESCE(\$3::uuid, sku_id)
        ORDER BY period_start, warehouse_id, sku_id
        LIMIT \$4
    """, [string(tenant_id), _sql_null(warehouse_filter), _sql_null(sku_filter), page.limit])
    return [_sql_demand_row(row) for row in result]
end

function _sql_lane_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])),
        :from_warehouse_id => UUID(String(row[3])), :to_warehouse_id => UUID(String(row[4])),
        :lead_time_days => Int(row[5]), :cost_per_unit_cents => Int(row[6]),
        :capacity_units_day => row[7], :active => Bool(row[8]),
    )
end

function fetch_transfer_lanes(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    warehouse_filter = haskey(page.filters, "warehouse_id") ? string(_uuid_value(page.filters["warehouse_id"])) : nothing
    active_filter = haskey(page.filters, "status") ? _active_filter(page.filters["status"]) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, from_warehouse_id, to_warehouse_id, lead_time_days, cost_per_unit_cents, capacity_units_day, active
        FROM transfer_lanes
        WHERE tenant_id = \$1
          AND (\$2::uuid IS NULL OR from_warehouse_id = \$2::uuid OR to_warehouse_id = \$2::uuid)
          AND active = COALESCE(\$3::boolean, active)
        ORDER BY from_warehouse_id, to_warehouse_id
        LIMIT \$4
    """, [string(tenant_id), _sql_null(warehouse_filter), _sql_null(active_filter), page.limit])
    return [_sql_lane_row(row) for row in result]
end

function persist_transfer_lane_create!(store::SqlTenantAdminStore, row)
    try
        LibPQ.execute(store.connection, """
            INSERT INTO transfer_lanes (id, tenant_id, from_warehouse_id, to_warehouse_id, lead_time_days, cost_per_unit_cents, capacity_units_day, active)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
        """, [string(row[:id]), string(row[:tenant_id]), string(row[:from_warehouse_id]), string(row[:to_warehouse_id]), row[:lead_time_days], row[:cost_per_unit_cents], _sql_null(row[:capacity_units_day]), row[:active]])
    catch err
        throw(ApiError("CONFLICT", "Transfer lane already exists for tenant"; status = 409))
    end
    return row
end

function _sql_policy_row(row)::Dict{Symbol,Any}
    config_value = _is_nullish(row[10]) ? Dict{String,Any}() : JSON3.read(String(row[10]))
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :name => row[3], :objective => row[4],
        :planning_horizon_days => Int(row[5]), :service_level_target => row[6], :max_transfer_cost_cents => row[7],
        :allow_cross_region => Bool(row[8]), :frozen_until => row[9], :config => config_value, :status => row[11],
    )
end

function fetch_allocation_policies(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    status_filter = haskey(page.filters, "status") ? _validate_choice("status", page.filters["status"], POLICY_STATUSES) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, name, objective, planning_horizon_days, service_level_target, max_transfer_cost_cents, allow_cross_region, frozen_until, config, status
        FROM allocation_policies
        WHERE tenant_id = \$1
          AND status = COALESCE(\$2::text, status)
        ORDER BY name
        LIMIT \$3
    """, [string(tenant_id), _sql_null(status_filter), page.limit])
    return [_sql_policy_row(row) for row in result]
end

function persist_allocation_policy_create!(store::SqlTenantAdminStore, row)
    try
        LibPQ.execute(store.connection, """
            INSERT INTO allocation_policies (id, tenant_id, name, objective, planning_horizon_days, service_level_target, max_transfer_cost_cents, allow_cross_region, frozen_until, config, status)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10::jsonb, \$11)
        """, [string(row[:id]), string(row[:tenant_id]), row[:name], row[:objective], row[:planning_horizon_days], row[:service_level_target], _sql_null(row[:max_transfer_cost_cents]), row[:allow_cross_region], _sql_null(row[:frozen_until]), JSON3.write(row[:config]), row[:status]])
    catch err
        throw(ApiError("CONFLICT", "Allocation policy name already exists for tenant"; status = 409))
    end
    return row
end
