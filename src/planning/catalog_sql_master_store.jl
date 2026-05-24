function _sql_warehouse_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :code => row[3],
        :name => row[4], :region => row[5], :latitude => row[6], :longitude => row[7],
        :capacity_units => row[8], :handling_cost_cents => Int(row[9]), :active => Bool(row[10]),
    )
end

function fetch_warehouses(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    region_filter = get(page.filters, "region", nothing)
    active_filter = haskey(page.filters, "status") ? _active_filter(page.filters["status"]) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, code, name, region, latitude, longitude, capacity_units, handling_cost_cents, active
        FROM warehouses
        WHERE tenant_id = \$1
          AND region = COALESCE(\$2::text, region)
          AND active = COALESCE(\$3::boolean, active)
        ORDER BY code
        LIMIT \$4
    """, [string(tenant_id), _sql_null(region_filter), _sql_null(active_filter), page.limit])
    return [_sql_warehouse_row(row) for row in result]
end

function fetch_warehouse(store::SqlTenantAdminStore, tenant_id::UUID, warehouse_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, code, name, region, latitude, longitude, capacity_units, handling_cost_cents, active
        FROM warehouses
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(warehouse_id)])
    isempty(result) && return nothing
    return _sql_warehouse_row(first(result))
end

function persist_warehouse_create!(store::SqlTenantAdminStore, row)
    try
        LibPQ.execute(store.connection, """
            INSERT INTO warehouses (id, tenant_id, code, name, region, latitude, longitude, capacity_units, handling_cost_cents, active)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
        """, [string(row[:id]), string(row[:tenant_id]), row[:code], row[:name], row[:region], _sql_null(row[:latitude]), _sql_null(row[:longitude]), row[:capacity_units], row[:handling_cost_cents], row[:active]])
    catch err
        throw(ApiError("CONFLICT", "Warehouse code already exists for tenant"; status = 409))
    end
    return row
end

function persist_warehouse_update!(store::SqlTenantAdminStore, row)
    try
        LibPQ.execute(store.connection, """
            UPDATE warehouses
            SET code = \$3, name = \$4, region = \$5, latitude = \$6, longitude = \$7,
                capacity_units = \$8, handling_cost_cents = \$9, active = \$10, updated_at = now()
            WHERE tenant_id = \$1 AND id = \$2
        """, [string(row[:tenant_id]), string(row[:id]), row[:code], row[:name], row[:region], _sql_null(row[:latitude]), _sql_null(row[:longitude]), row[:capacity_units], row[:handling_cost_cents], row[:active]])
    catch err
        throw(ApiError("CONFLICT", "Warehouse code already exists for tenant"; status = 409))
    end
    return row
end

function _sql_sku_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :sku_code => row[3],
        :name => row[4], :category => row[5], :unit_volume => row[6], :unit_margin_cents => Int(row[7]),
        :stockout_cost_cents => Int(row[8]), :holding_cost_cents => Int(row[9]), :active => Bool(row[10]),
    )
end

function fetch_skus(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    category_filter = get(page.filters, "category", nothing)
    active_filter = haskey(page.filters, "status") ? _active_filter(page.filters["status"]) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, sku_code, name, category, unit_volume, unit_margin_cents, stockout_cost_cents, holding_cost_cents, active
        FROM skus
        WHERE tenant_id = \$1
          AND category = COALESCE(\$2::text, category)
          AND active = COALESCE(\$3::boolean, active)
        ORDER BY sku_code
        LIMIT \$4
    """, [string(tenant_id), _sql_null(category_filter), _sql_null(active_filter), page.limit])
    return [_sql_sku_row(row) for row in result]
end

function fetch_sku(store::SqlTenantAdminStore, tenant_id::UUID, sku_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, sku_code, name, category, unit_volume, unit_margin_cents, stockout_cost_cents, holding_cost_cents, active
        FROM skus
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(sku_id)])
    isempty(result) && return nothing
    return _sql_sku_row(first(result))
end

function persist_sku_create!(store::SqlTenantAdminStore, row)
    try
        LibPQ.execute(store.connection, """
            INSERT INTO skus (id, tenant_id, sku_code, name, category, unit_volume, unit_margin_cents, stockout_cost_cents, holding_cost_cents, active)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
        """, [string(row[:id]), string(row[:tenant_id]), row[:sku_code], row[:name], row[:category], row[:unit_volume], row[:unit_margin_cents], row[:stockout_cost_cents], row[:holding_cost_cents], row[:active]])
    catch err
        throw(ApiError("CONFLICT", "SKU code already exists for tenant"; status = 409))
    end
    return row
end

function persist_sku_update!(store::SqlTenantAdminStore, row)
    try
        LibPQ.execute(store.connection, """
            UPDATE skus
            SET sku_code = \$3, name = \$4, category = \$5, unit_volume = \$6,
                unit_margin_cents = \$7, stockout_cost_cents = \$8, holding_cost_cents = \$9,
                active = \$10, updated_at = now()
            WHERE tenant_id = \$1 AND id = \$2
        """, [string(row[:tenant_id]), string(row[:id]), row[:sku_code], row[:name], row[:category], row[:unit_volume], row[:unit_margin_cents], row[:stockout_cost_cents], row[:holding_cost_cents], row[:active]])
    catch err
        throw(ApiError("CONFLICT", "SKU code already exists for tenant"; status = 409))
    end
    return row
end
