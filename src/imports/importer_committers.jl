function _upsert_warehouse_from_import!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::Nothing
    existing = _find_warehouse_by_code(store, ctx.tenant_id, payload["code"])
    row = existing === nothing ? _warehouse_payload(ctx, payload) : _warehouse_payload(ctx, payload; current = existing)
    existing === nothing ? persist_warehouse_create!(store, row) : persist_warehouse_update!(store, row)
    return nothing
end

function _upsert_sku_from_import!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::Nothing
    existing = _find_sku_by_code(store, ctx.tenant_id, payload["sku_code"])
    row = existing === nothing ? _sku_payload(ctx, payload) : _sku_payload(ctx, payload; current = existing)
    existing === nothing ? persist_sku_create!(store, row) : persist_sku_update!(store, row)
    return nothing
end

function _upsert_demand_from_import!(store::MemoryTenantAdminStore, tenant_id::UUID, warehouse, sku, period_start, period_end, demand_units, lost_sales_units, source)::Nothing
    existing_id = nothing
    for row in values(store.demand_history)
        if row[:tenant_id] == tenant_id && row[:warehouse_id] == warehouse[:id] && row[:sku_id] == sku[:id] && row[:period_start] == period_start
            existing_id = row[:id]
            break
        end
    end
    id = existing_id === nothing ? uuid4() : existing_id
    store.demand_history[id] = Dict{Symbol,Any}(
        :id => id, :tenant_id => tenant_id, :warehouse_id => warehouse[:id], :sku_id => sku[:id],
        :period_start => period_start, :period_end => period_end, :demand_units => demand_units,
        :lost_sales_units => lost_sales_units, :source => source,
    )
    return nothing
end

function _upsert_demand_from_import!(store::SqlTenantAdminStore, tenant_id::UUID, warehouse, sku, period_start, period_end, demand_units, lost_sales_units, source)::Nothing
    LibPQ.execute(store.connection, """
        INSERT INTO demand_history (id, tenant_id, warehouse_id, sku_id, period_start, period_end, demand_units, lost_sales_units, source)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9)
        ON CONFLICT (tenant_id, sku_id, warehouse_id, period_start) DO UPDATE SET
            period_end = EXCLUDED.period_end,
            demand_units = EXCLUDED.demand_units,
            lost_sales_units = EXCLUDED.lost_sales_units,
            source = EXCLUDED.source,
            updated_at = now()
    """, [string(uuid4()), string(tenant_id), string(warehouse[:id]), string(sku[:id]), period_start, period_end, demand_units, lost_sales_units, source])
    return nothing
end

function _upsert_lane_from_import!(store::MemoryTenantAdminStore, tenant_id::UUID, from_warehouse, to_warehouse, lead_time, cost, capacity, active)::Nothing
    existing_id = nothing
    for row in values(store.transfer_lanes)
        if row[:tenant_id] == tenant_id && row[:from_warehouse_id] == from_warehouse[:id] && row[:to_warehouse_id] == to_warehouse[:id]
            existing_id = row[:id]
            break
        end
    end
    id = existing_id === nothing ? uuid4() : existing_id
    store.transfer_lanes[id] = Dict{Symbol,Any}(
        :id => id, :tenant_id => tenant_id, :from_warehouse_id => from_warehouse[:id], :to_warehouse_id => to_warehouse[:id],
        :lead_time_days => lead_time, :cost_per_unit_cents => cost, :capacity_units_day => capacity, :active => active,
    )
    return nothing
end

function _upsert_lane_from_import!(store::SqlTenantAdminStore, tenant_id::UUID, from_warehouse, to_warehouse, lead_time, cost, capacity, active)::Nothing
    LibPQ.execute(store.connection, """
        INSERT INTO transfer_lanes (id, tenant_id, from_warehouse_id, to_warehouse_id, lead_time_days, cost_per_unit_cents, capacity_units_day, active)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
        ON CONFLICT (tenant_id, from_warehouse_id, to_warehouse_id) DO UPDATE SET
            lead_time_days = EXCLUDED.lead_time_days,
            cost_per_unit_cents = EXCLUDED.cost_per_unit_cents,
            capacity_units_day = EXCLUDED.capacity_units_day,
            active = EXCLUDED.active,
            updated_at = now()
    """, [string(uuid4()), string(tenant_id), string(from_warehouse[:id]), string(to_warehouse[:id]), lead_time, cost, _sql_null(capacity), active])
    return nothing
end

function _validate_import_row(store::AbstractTenantAdminStore, ctx::TenantContext, import_type::AbstractString, rownum::Int, data::Dict{String,String})
    import_type == "warehouses" && return _validate_warehouse_import_row(ctx, rownum, data)
    import_type == "skus" && return _validate_sku_import_row(ctx, rownum, data)
    if import_type == "inventory"
        row_errors, warehouse, sku, on_hand, reserved, inbound, safety, source = _validate_inventory_import_row(store, ctx.tenant_id, rownum, data)
        return row_errors, (warehouse, sku, on_hand, reserved, inbound, safety, source)
    end
    import_type == "demand" && return _validate_demand_import_row(store, ctx.tenant_id, rownum, data)
    import_type == "lanes" && return _validate_lane_import_row(store, ctx.tenant_id, rownum, data)
    throw(ApiError("VALIDATION_ERROR", "import_type is invalid"; status = 400))
end

function _commit_import_row!(store::AbstractTenantAdminStore, ctx::TenantContext, import_type::AbstractString, valid)::Nothing
    if import_type == "warehouses"
        _upsert_warehouse_from_import!(store, ctx, valid)
    elseif import_type == "skus"
        _upsert_sku_from_import!(store, ctx, valid)
    elseif import_type == "inventory"
        warehouse, sku, on_hand, reserved, inbound, safety, source = valid
        _upsert_inventory_from_import!(store, ctx.tenant_id, warehouse, sku, on_hand, reserved, inbound, safety, source)
    elseif import_type == "demand"
        warehouse, sku, period_start, period_end, demand_units, lost_sales_units, source = valid
        _upsert_demand_from_import!(store, ctx.tenant_id, warehouse, sku, period_start, period_end, demand_units, lost_sales_units, source)
    elseif import_type == "lanes"
        from_warehouse, to_warehouse, lead_time, cost, capacity, active = valid
        _upsert_lane_from_import!(store, ctx.tenant_id, from_warehouse, to_warehouse, lead_time, cost, capacity, active)
    end
    return nothing
end

function _persist_import_job_result!(store::MemoryTenantAdminStore, row, status::AbstractString, errors::Vector{NamedTuple}, committed_rows::Int)
    row[:status] = String(status)
    row[:error_report] = errors
    row[:committed_rows] = committed_rows
    return row
end

function _persist_import_job_result!(store::SqlTenantAdminStore, row, status::AbstractString, errors::Vector{NamedTuple}, committed_rows::Int)
    row[:status] = String(status)
    row[:error_report] = errors
    row[:committed_rows] = committed_rows
    LibPQ.execute(store.connection, """
        UPDATE import_jobs
        SET status = \$3, row_count = \$4, error_report = \$5::jsonb, updated_at = now()
        WHERE tenant_id = \$1 AND id = \$2
    """, [string(row[:tenant_id]), string(row[:id]), String(status), row[:row_count], JSON3.write(errors)])
    return row
end

function _with_import_transaction!(store::AbstractTenantAdminStore, work::Function)
    return work()
end

function _with_import_transaction!(store::SqlTenantAdminStore, work::Function)
    LibPQ.execute(store.connection, "BEGIN")
    try
        result = work()
        LibPQ.execute(store.connection, "COMMIT")
        return result
    catch
        LibPQ.execute(store.connection, "ROLLBACK")
        rethrow()
    end
end

function _process_import_job!(store::AbstractTenantAdminStore, config::AppConfig, ctx::TenantContext, job_id)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    row = fetch_import_job(store, ctx.tenant_id, _uuid_value(job_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Import job not found"; status = 404))
    content = read(row[:file_path], String)
    _enforce_import_size!(config, content)
    headers, rows = _csv_rows(content)
    _validate_import_headers(row[:import_type], headers)
    row[:row_count] = length(rows)

    valid = Any[]
    errors = NamedTuple[]
    for (rownum, data) in rows
        row_errors, valid_row = _validate_import_row(store, ctx, row[:import_type], rownum, data)
        append!(errors, row_errors)
        isempty(row_errors) && push!(valid, valid_row)
    end

    committed = 0
    status = isempty(errors) || config.imports.partial_commit ? "completed" : "failed"
    _with_import_transaction!(store, function ()
        if isempty(errors) || config.imports.partial_commit
            for valid_row in valid
                _commit_import_row!(store, ctx, row[:import_type], valid_row)
                committed += 1
            end
        end
        _persist_import_job_result!(store, row, status, errors, committed)
        return nothing
    end)
    return _import_job_response(row)
end

function process_import_job!(store::AbstractTenantAdminStore, config::AppConfig, ctx::TenantContext, job_id)::NamedTuple
    return _process_import_job!(store, config, ctx, job_id)
end

function process_import_job!(store::SqlTenantAdminStore, config::AppConfig, ctx::TenantContext, job_id)::NamedTuple
    return _process_import_job!(store, config, ctx, job_id)
end
