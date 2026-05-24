using LibPQ
using UUIDs

const PLANNING_READ_ACTION = "read"
const PLANNING_WRITE_ACTION = "write_import"
const PLANNING_RESOURCE = "planning_data"

function _page_response(key::Symbol, rows::AbstractVector, page::CursorPageRequest)::NamedTuple
    return NamedTuple{(key, :page)}((rows, (limit = page.limit, next_cursor = nothing)))
end

function _uuid_value(value)::UUID
    value isa UUID && return value
    return UUID(String(value))
end

function _active_filter(value)::Bool
    lowered = lowercase(strip(String(value)))
    lowered in ("active", "true", "1") && return true
    lowered in ("inactive", "false", "0") && return false
    throw(ApiError("VALIDATION_ERROR", "status must be active or inactive"; status = 400))
end

function _required_decimal(payload, key::AbstractString)::Float64
    value = _payload_get(payload, key, nothing)
    value === nothing && throw(ApiError("VALIDATION_ERROR", "$key is required"; status = 400))
    parsed = value isa Number ? Float64(value) : tryparse(Float64, strip(String(value)))
    parsed === nothing && throw(ApiError("VALIDATION_ERROR", "$key must be numeric"; status = 400))
    return parsed
end

function _optional_decimal(payload, key::AbstractString, default)::Float64
    value = _payload_get(payload, key, nothing)
    value === nothing && return Float64(default)
    parsed = value isa Number ? Float64(value) : tryparse(Float64, strip(String(value)))
    parsed === nothing && throw(ApiError("VALIDATION_ERROR", "$key must be numeric"; status = 400))
    return parsed
end

function _optional_nullable_decimal(payload, key::AbstractString, default)::Union{Nothing,Float64}
    value = _payload_get(payload, key, nothing)
    value === nothing && return default
    value === missing && return nothing
    parsed = value isa Number ? Float64(value) : tryparse(Float64, strip(String(value)))
    parsed === nothing && throw(ApiError("VALIDATION_ERROR", "$key must be numeric"; status = 400))
    return parsed
end

function _optional_int(payload, key::AbstractString, default)::Int
    value = _payload_get(payload, key, nothing)
    value === nothing && return Int(default)
    parsed = value isa Integer ? Int(value) : tryparse(Int, strip(String(value)))
    parsed === nothing && throw(ApiError("VALIDATION_ERROR", "$key must be an integer"; status = 400))
    return parsed
end

function _validate_nonnegative(name::AbstractString, value::Real)
    value < 0 && throw(ApiError("VALIDATION_ERROR", "$name must be non-negative"; status = 400))
    return value
end

function _validate_positive(name::AbstractString, value::Real)
    value > 0 || throw(ApiError("VALIDATION_ERROR", "$name must be greater than zero"; status = 400))
    return value
end

function _validate_latitude(value::Union{Nothing,Float64})
    value === nothing && return nothing
    (-90 <= value <= 90) || throw(ApiError("VALIDATION_ERROR", "latitude must be between -90 and 90"; status = 400))
    return value
end

function _validate_longitude(value::Union{Nothing,Float64})
    value === nothing && return nothing
    (-180 <= value <= 180) || throw(ApiError("VALIDATION_ERROR", "longitude must be between -180 and 180"; status = 400))
    return value
end

function _warehouse_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        code = String(row[:code]),
        name = String(row[:name]),
        region = String(row[:region]),
        latitude = _is_nullish(row[:latitude]) ? nothing : Float64(row[:latitude]),
        longitude = _is_nullish(row[:longitude]) ? nothing : Float64(row[:longitude]),
        capacity_units = Float64(row[:capacity_units]),
        handling_cost_cents = Int(row[:handling_cost_cents]),
        active = Bool(row[:active]),
    )
end

function _sku_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        sku_code = String(row[:sku_code]),
        name = String(row[:name]),
        category = String(row[:category]),
        unit_volume = Float64(row[:unit_volume]),
        unit_margin_cents = Int(row[:unit_margin_cents]),
        stockout_cost_cents = Int(row[:stockout_cost_cents]),
        holding_cost_cents = Int(row[:holding_cost_cents]),
        active = Bool(row[:active]),
    )
end

function _warehouse_payload(ctx::TenantContext, payload; current = nothing)::Dict{Symbol,Any}
    capacity_default = current === nothing ? nothing : current[:capacity_units]
    capacity = capacity_default === nothing ? _required_decimal(payload, "capacity_units") : _optional_decimal(payload, "capacity_units", capacity_default)
    latitude = _validate_latitude(_optional_nullable_decimal(payload, "latitude", current === nothing ? nothing : current[:latitude]))
    longitude = _validate_longitude(_optional_nullable_decimal(payload, "longitude", current === nothing ? nothing : current[:longitude]))
    _validate_positive("capacity_units", capacity)
    handling = _validate_nonnegative("handling_cost_cents", _optional_int(payload, "handling_cost_cents", current === nothing ? 0 : current[:handling_cost_cents]))
    return Dict{Symbol,Any}(
        :id => current === nothing ? uuid4() : current[:id],
        :tenant_id => ctx.tenant_id,
        :code => current === nothing ? uppercase(_required_text(payload, "code")) : uppercase(something(_optional_text(payload, "code"), current[:code])),
        :name => current === nothing ? _required_text(payload, "name") : something(_optional_text(payload, "name"), current[:name]),
        :region => current === nothing ? _required_text(payload, "region") : something(_optional_text(payload, "region"), current[:region]),
        :latitude => latitude,
        :longitude => longitude,
        :capacity_units => Float64(capacity),
        :handling_cost_cents => Int(handling),
        :active => something(_optional_bool(payload, "active"), current === nothing ? true : current[:active]),
    )
end

function _sku_payload(ctx::TenantContext, payload; current = nothing)::Dict{Symbol,Any}
    unit_volume = _validate_positive("unit_volume", _optional_decimal(payload, "unit_volume", current === nothing ? 1 : current[:unit_volume]))
    unit_margin = _validate_nonnegative("unit_margin_cents", _optional_int(payload, "unit_margin_cents", current === nothing ? 0 : current[:unit_margin_cents]))
    stockout_cost = _validate_nonnegative("stockout_cost_cents", _optional_int(payload, "stockout_cost_cents", current === nothing ? 0 : current[:stockout_cost_cents]))
    holding_cost = _validate_nonnegative("holding_cost_cents", _optional_int(payload, "holding_cost_cents", current === nothing ? 0 : current[:holding_cost_cents]))
    return Dict{Symbol,Any}(
        :id => current === nothing ? uuid4() : current[:id],
        :tenant_id => ctx.tenant_id,
        :sku_code => current === nothing ? uppercase(_required_text(payload, "sku_code")) : uppercase(something(_optional_text(payload, "sku_code"), current[:sku_code])),
        :name => current === nothing ? _required_text(payload, "name") : something(_optional_text(payload, "name"), current[:name]),
        :category => current === nothing ? _required_text(payload, "category") : something(_optional_text(payload, "category"), current[:category]),
        :unit_volume => Float64(unit_volume),
        :unit_margin_cents => Int(unit_margin),
        :stockout_cost_cents => Int(stockout_cost),
        :holding_cost_cents => Int(holding_cost),
        :active => something(_optional_bool(payload, "active"), current === nothing ? true : current[:active]),
    )
end

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
    """, [string(tenant_id), region_filter, active_filter, page.limit])
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
        """, [string(row[:id]), string(row[:tenant_id]), row[:code], row[:name], row[:region], row[:latitude], row[:longitude], row[:capacity_units], row[:handling_cost_cents], row[:active]])
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
        """, [string(row[:tenant_id]), string(row[:id]), row[:code], row[:name], row[:region], row[:latitude], row[:longitude], row[:capacity_units], row[:handling_cost_cents], row[:active]])
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
    """, [string(tenant_id), category_filter, active_filter, page.limit])
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
