using Dates
using LibPQ
using UUIDs

const IMPORT_JOB_TYPES = Set(["warehouses", "skus", "inventory", "demand", "lanes"])
const IMPORT_REQUIRED_HEADERS = Dict(
    "warehouses" => ["code", "name", "region", "capacity_units"],
    "skus" => ["sku_code", "name", "category"],
    "inventory" => ["warehouse_code", "sku_code", "on_hand_units"],
    "demand" => ["warehouse_code", "sku_code", "period_start", "period_end", "demand_units"],
    "lanes" => ["from_warehouse_code", "to_warehouse_code", "lead_time_days"],
)

function _import_job_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        import_type = String(row[:import_type]),
        status = String(row[:status]),
        original_filename = String(row[:original_filename]),
        file_path = String(row[:file_path]),
        row_count = Int(row[:row_count]),
        error_report = get(row, :error_report, NamedTuple[]),
        committed_rows = Int(get(row, :committed_rows, 0)),
    )
end

function _validate_import_type(import_type)::String
    value = strip(String(import_type))
    value in IMPORT_JOB_TYPES || throw(ApiError("VALIDATION_ERROR", "import_type is invalid"; status = 400))
    return value
end

function _safe_filename(filename)::String
    cleaned = replace(basename(String(filename)), r"[^A-Za-z0-9_.-]" => "_")
    isempty(cleaned) && throw(ApiError("VALIDATION_ERROR", "original_filename is required"; status = 400))
    return cleaned
end

function _csv_rows(content::AbstractString)::Tuple{Vector{String},Vector{Tuple{Int,Dict{String,String}}}}
    lines = split(replace(content, "\r\n" => "\n"), '\n')
    while !isempty(lines) && isempty(strip(last(lines)))
        pop!(lines)
    end
    isempty(lines) && throw(ApiError("VALIDATION_ERROR", "CSV file is empty"; status = 400))
    headers = [strip(header) for header in split(first(lines), ',')]
    rows = Tuple{Int,Dict{String,String}}[]
    for (offset, line) in enumerate(lines[2:end])
        isempty(strip(line)) && continue
        values = [strip(value) for value in split(line, ',')]
        mapped = Dict{String,String}()
        for (idx, header) in enumerate(headers)
            mapped[header] = idx <= length(values) ? values[idx] : ""
        end
        push!(rows, (offset + 1, mapped))
    end
    return headers, rows
end

function _row_error(row::Int, field::AbstractString, code::AbstractString, message::AbstractString)::NamedTuple
    return (row = row, field = String(field), code = String(code), message = String(message))
end

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

function _parse_import_decimal(value::AbstractString, field::AbstractString, rownum::Int, errors::Vector{NamedTuple})
    parsed = tryparse(Float64, strip(value))
    if parsed === nothing
        push!(errors, _row_error(rownum, field, "INVALID_NUMBER", "$field must be numeric"))
        return nothing
    elseif parsed < 0
        push!(errors, _row_error(rownum, field, "NEGATIVE_INVENTORY", "$field must be non-negative"))
        return nothing
    end
    return parsed
end

function _validate_inventory_import_row(store::AbstractTenantAdminStore, tenant_id::UUID, rownum::Int, row::Dict{String,String})
    errors = NamedTuple[]
    warehouse = _find_warehouse_by_code(store, tenant_id, get(row, "warehouse_code", ""))
    sku = _find_sku_by_code(store, tenant_id, get(row, "sku_code", ""))
    warehouse === nothing && push!(errors, _row_error(rownum, "warehouse_code", "UNKNOWN_WAREHOUSE", "warehouse_code must match a tenant warehouse"))
    sku === nothing && push!(errors, _row_error(rownum, "sku_code", "UNKNOWN_SKU", "sku_code must match a tenant SKU"))
    on_hand = _parse_import_decimal(get(row, "on_hand_units", ""), "on_hand_units", rownum, errors)
    reserved = _parse_import_decimal(get(row, "reserved_units", "0"), "reserved_units", rownum, errors)
    inbound = _parse_import_decimal(get(row, "inbound_units", "0"), "inbound_units", rownum, errors)
    safety = _parse_import_decimal(get(row, "safety_stock_units", "0"), "safety_stock_units", rownum, errors)
    source = strip(get(row, "source", "csv"))
    if !(source in INVENTORY_SOURCES)
        push!(errors, _row_error(rownum, "source", "INVALID_SOURCE", "source must be manual, csv, api, or simulation"))
    end
    return errors, warehouse, sku, on_hand, reserved, inbound, safety, source
end

function _upsert_inventory_from_import!(store::MemoryTenantAdminStore, tenant_id::UUID, warehouse, sku, on_hand, reserved, inbound, safety, source)::Nothing
    existing_id = nothing
    for row in values(store.inventory_positions)
        if row[:tenant_id] == tenant_id && row[:warehouse_id] == warehouse[:id] && row[:sku_id] == sku[:id]
            existing_id = row[:id]
            break
        end
    end
    id = existing_id === nothing ? uuid4() : existing_id
    store.inventory_positions[id] = Dict{Symbol,Any}(
        :id => id,
        :tenant_id => tenant_id,
        :warehouse_id => warehouse[:id],
        :sku_id => sku[:id],
        :on_hand_units => on_hand,
        :reserved_units => reserved,
        :inbound_units => inbound,
        :safety_stock_units => safety,
        :as_of => now(),
        :source => source,
    )
    return nothing
end

function _upsert_inventory_from_import!(store::SqlTenantAdminStore, tenant_id::UUID, warehouse, sku, on_hand, reserved, inbound, safety, source)::Nothing
    LibPQ.execute(store.connection, """
        INSERT INTO inventory_positions (id, tenant_id, warehouse_id, sku_id, on_hand_units, reserved_units, inbound_units, safety_stock_units, as_of, source)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, now(), \$9)
        ON CONFLICT (tenant_id, warehouse_id, sku_id) DO UPDATE SET
            on_hand_units = EXCLUDED.on_hand_units,
            reserved_units = EXCLUDED.reserved_units,
            inbound_units = EXCLUDED.inbound_units,
            safety_stock_units = EXCLUDED.safety_stock_units,
            as_of = EXCLUDED.as_of,
            source = EXCLUDED.source,
            updated_at = now()
    """, [string(uuid4()), string(tenant_id), string(warehouse[:id]), string(sku[:id]), on_hand, reserved, inbound, safety, source])
    return nothing
end

function _required_import_text(row::Dict{String,String}, key::AbstractString, rownum::Int, errors::Vector{NamedTuple})::String
    value = strip(get(row, String(key), ""))
    isempty(value) && push!(errors, _row_error(rownum, key, "REQUIRED", "$key is required"))
    return value
end

function _optional_import_decimal(row::Dict{String,String}, key::AbstractString, default, rownum::Int, errors::Vector{NamedTuple})
    value = strip(get(row, String(key), ""))
    isempty(value) && return default
    return _parse_import_decimal(value, key, rownum, errors)
end

function _parse_import_int(row::Dict{String,String}, key::AbstractString, default, rownum::Int, errors::Vector{NamedTuple})
    value = strip(get(row, String(key), ""))
    isempty(value) && return default
    parsed = tryparse(Int, value)
    if parsed === nothing
        push!(errors, _row_error(rownum, key, "INVALID_INTEGER", "$key must be an integer"))
        return nothing
    elseif parsed < 0
        push!(errors, _row_error(rownum, key, "NEGATIVE_NUMBER", "$key must be non-negative"))
        return nothing
    end
    return parsed
end

function _parse_import_date(row::Dict{String,String}, key::AbstractString, rownum::Int, errors::Vector{NamedTuple})
    value = _required_import_text(row, key, rownum, errors)
    isempty(value) && return nothing
    parsed = tryparse(Date, value)
    parsed === nothing && push!(errors, _row_error(rownum, key, "INVALID_DATE", "$key must be an ISO date"))
    return parsed
end

function _parse_import_bool(row::Dict{String,String}, key::AbstractString, default, rownum::Int, errors::Vector{NamedTuple})
    value = strip(get(row, String(key), ""))
    isempty(value) && return default
    lowered = lowercase(value)
    lowered in ("true", "1", "yes", "active") && return true
    lowered in ("false", "0", "no", "inactive") && return false
    push!(errors, _row_error(rownum, key, "INVALID_BOOLEAN", "$key must be true or false"))
    return nothing
end

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

function _validate_import_headers(import_type::AbstractString, headers::Vector{String})::Nothing
    required = IMPORT_REQUIRED_HEADERS[String(import_type)]
    missing_headers = [header for header in required if !(header in headers)]
    isempty(missing_headers) || throw(ApiError("VALIDATION_ERROR", "CSV headers are invalid"; status = 400, details = [(missing = missing_headers,)]))
    return nothing
end

function _enforce_import_size!(config::AppConfig, content::AbstractString)::Nothing
    max_bytes = config.imports.max_import_mb * 1024 * 1024
    if sizeof(String(content)) > max_bytes
        throw(ApiError("PAYLOAD_TOO_LARGE", "CSV import exceeds MAX_IMPORT_MB"; status = 413, details = [(max_import_mb = config.imports.max_import_mb,)]))
    end
    return nothing
end

function create_import_job!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    ctx::TenantContext,
    import_type,
    original_filename,
    content::AbstractString,
)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    parsed_type = _validate_import_type(import_type)
    _enforce_import_size!(config, content)
    headers, rows = _csv_rows(content)
    _validate_import_headers(parsed_type, headers)
    id = uuid4()
    tenant_dir = joinpath(config.imports.upload_storage_path, string(ctx.tenant_id))
    mkpath(tenant_dir)
    file_path = joinpath(tenant_dir, string(id, "-", _safe_filename(original_filename)))
    write(file_path, content)
    row = Dict{Symbol,Any}(
        :id => id,
        :tenant_id => ctx.tenant_id,
        :import_type => parsed_type,
        :status => "queued",
        :original_filename => _safe_filename(original_filename),
        :file_path => file_path,
        :row_count => length(rows),
        :error_report => NamedTuple[],
        :committed_rows => 0,
    )
    persist_import_job_create!(store, row)
    return _import_job_response(row)
end

function persist_import_job_create!(store::MemoryTenantAdminStore, row)
    store.import_jobs[row[:id]] = row
    return row
end

function persist_import_job_create!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO import_jobs (id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8::jsonb)
    """, [string(row[:id]), string(row[:tenant_id]), row[:import_type], row[:status], row[:original_filename], row[:file_path], row[:row_count], JSON3.write(row[:error_report])])
    return row
end

function fetch_import_job(store::MemoryTenantAdminStore, tenant_id::UUID, job_id::UUID)
    row = get(store.import_jobs, job_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function _sql_import_job_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])),
        :tenant_id => UUID(String(row[2])),
        :import_type => row[3],
        :status => row[4],
        :original_filename => row[5],
        :file_path => row[6],
        :row_count => Int(row[7]),
        :error_report => JSON3.read(String(row[8])),
        :committed_rows => 0,
    )
end

function fetch_import_job(store::SqlTenantAdminStore, tenant_id::UUID, job_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
        FROM import_jobs
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(job_id)])
    isempty(result) && return nothing
    return _sql_import_job_row(first(result))
end

function get_import_result(store::AbstractTenantAdminStore, ctx::TenantContext, job_id)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = fetch_import_job(store, ctx.tenant_id, _uuid_value(job_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Import job not found"; status = 404))
    return _import_job_response(row)
end

function claim_next_import_job!(store::MemoryTenantAdminStore, ctx::TenantContext; worker_id::AbstractString = "import-worker")
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    queued = sort([row for row in values(store.import_jobs) if row[:tenant_id] == ctx.tenant_id && row[:status] == "queued"]; by = row -> row[:id])
    isempty(queued) && return nothing
    row = first(queued)
    row[:status] = "running"
    row[:worker_id] = String(worker_id)
    return _import_job_response(row)
end

function claim_next_import_job!(store::SqlTenantAdminStore, ctx::TenantContext; worker_id::AbstractString = "import-worker")
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    result = LibPQ.execute(store.connection, """
        UPDATE import_jobs
        SET status = 'running', updated_at = now()
        WHERE id = (
            SELECT id FROM import_jobs
            WHERE tenant_id = \$1 AND status = 'queued'
            ORDER BY created_at
            LIMIT 1
        )
        RETURNING id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
    """, [string(ctx.tenant_id)])
    isempty(result) && return nothing
    return _import_job_response(_sql_import_job_row(first(result)))
end

function claim_next_import_job!(store::SqlTenantAdminStore; worker_id::AbstractString = "import-worker")
    result = LibPQ.execute(store.connection, """
        UPDATE import_jobs
        SET status = 'running', updated_at = now()
        WHERE id = (
            SELECT id FROM import_jobs
            WHERE status = 'queued'
            ORDER BY created_at
            LIMIT 1
        )
        RETURNING id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
    """)
    isempty(result) && return nothing
    return _import_job_response(_sql_import_job_row(first(result)))
end

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

function _fetch_import_job_by_id(store::SqlTenantAdminStore, job_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
        FROM import_jobs
        WHERE id = \$1
        LIMIT 1
    """, [string(job_id)])
    isempty(result) && return nothing
    return _sql_import_job_row(first(result))
end

function process_import_job!(store::SqlTenantAdminStore, config::AppConfig, job_id)::NamedTuple
    row = _fetch_import_job_by_id(store, _uuid_value(job_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Import job not found"; status = 404))
    ctx = TenantContext(row[:tenant_id]; role = "admin", auth_method = :job)
    return _process_import_job!(store, config, ctx, job_id)
end
