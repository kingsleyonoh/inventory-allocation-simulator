function _validate_warehouse_import_row(ctx::TenantContext, rownum::Int, row::Dict{String,String})
    errors = NamedTuple[]
    payload = Dict{String,Any}()
    for key in ("code", "name", "region")
        payload[key] = _required_import_text(row, key, rownum, errors)
    end
    payload["capacity_units"] = _parse_import_decimal(get(row, "capacity_units", ""), "capacity_units", rownum, errors)
    payload["handling_cost_cents"] = _parse_import_int(row, "handling_cost_cents", 0, rownum, errors)
    payload["latitude"] = _optional_import_decimal(row, "latitude", nothing, rownum, errors)
    payload["longitude"] = _optional_import_decimal(row, "longitude", nothing, rownum, errors)
    payload["active"] = _parse_import_bool(row, "active", true, rownum, errors)
    return errors, payload
end

function _validate_sku_import_row(ctx::TenantContext, rownum::Int, row::Dict{String,String})
    errors = NamedTuple[]
    payload = Dict{String,Any}()
    for key in ("sku_code", "name", "category")
        payload[key] = _required_import_text(row, key, rownum, errors)
    end
    payload["unit_volume"] = _optional_import_decimal(row, "unit_volume", 1.0, rownum, errors)
    payload["unit_margin_cents"] = _parse_import_int(row, "unit_margin_cents", 0, rownum, errors)
    payload["stockout_cost_cents"] = _parse_import_int(row, "stockout_cost_cents", 0, rownum, errors)
    payload["holding_cost_cents"] = _parse_import_int(row, "holding_cost_cents", 0, rownum, errors)
    payload["active"] = _parse_import_bool(row, "active", true, rownum, errors)
    return errors, payload
end

function _validate_demand_import_row(store::AbstractTenantAdminStore, tenant_id::UUID, rownum::Int, row::Dict{String,String})
    errors = NamedTuple[]
    warehouse = _find_warehouse_by_code(store, tenant_id, get(row, "warehouse_code", ""))
    sku = _find_sku_by_code(store, tenant_id, get(row, "sku_code", ""))
    warehouse === nothing && push!(errors, _row_error(rownum, "warehouse_code", "UNKNOWN_WAREHOUSE", "warehouse_code must match a tenant warehouse"))
    sku === nothing && push!(errors, _row_error(rownum, "sku_code", "UNKNOWN_SKU", "sku_code must match a tenant SKU"))
    period_start = _parse_import_date(row, "period_start", rownum, errors)
    period_end = _parse_import_date(row, "period_end", rownum, errors)
    demand_units = _parse_import_decimal(get(row, "demand_units", ""), "demand_units", rownum, errors)
    lost_sales_units = _optional_import_decimal(row, "lost_sales_units", 0.0, rownum, errors)
    source = strip(get(row, "source", "csv"))
    if !(source in DEMAND_SOURCES)
        push!(errors, _row_error(rownum, "source", "INVALID_SOURCE", "source must be manual, csv, or api"))
    end
    return errors, (warehouse, sku, period_start, period_end, demand_units, lost_sales_units, source)
end

function _validate_lane_import_row(store::AbstractTenantAdminStore, tenant_id::UUID, rownum::Int, row::Dict{String,String})
    errors = NamedTuple[]
    from_warehouse = _find_warehouse_by_code(store, tenant_id, get(row, "from_warehouse_code", ""))
    to_warehouse = _find_warehouse_by_code(store, tenant_id, get(row, "to_warehouse_code", ""))
    from_warehouse === nothing && push!(errors, _row_error(rownum, "from_warehouse_code", "UNKNOWN_WAREHOUSE", "from_warehouse_code must match a tenant warehouse"))
    to_warehouse === nothing && push!(errors, _row_error(rownum, "to_warehouse_code", "UNKNOWN_WAREHOUSE", "to_warehouse_code must match a tenant warehouse"))
    if from_warehouse !== nothing && to_warehouse !== nothing && from_warehouse[:id] == to_warehouse[:id]
        push!(errors, _row_error(rownum, "to_warehouse_code", "INVALID_LANE", "lane endpoints must differ"))
    end
    lead_time = _parse_import_int(row, "lead_time_days", nothing, rownum, errors)
    cost = _parse_import_int(row, "cost_per_unit_cents", 0, rownum, errors)
    capacity = _optional_import_decimal(row, "capacity_units_day", nothing, rownum, errors)
    active = _parse_import_bool(row, "active", true, rownum, errors)
    return errors, (from_warehouse, to_warehouse, lead_time, cost, capacity, active)
end
