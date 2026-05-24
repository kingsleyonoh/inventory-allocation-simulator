using Dates
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
    try
        return UUID(strip(String(value)))
    catch err
        err isa ArgumentError || rethrow(err)
        throw(ApiError("VALIDATION_ERROR", "UUID value is malformed"; status = 400))
    end
end

_sql_null(value) = value === nothing ? missing : value

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

const INVENTORY_SOURCES = Set(["manual", "csv", "api", "simulation"])
const DEMAND_SOURCES = Set(["manual", "csv", "api"])
const POLICY_OBJECTIVES = Set(["minimize_stockout_cost", "maximize_margin", "minimize_total_cost", "balanced"])
const POLICY_STATUSES = Set(["draft", "active", "archived"])

function _validate_choice(name::AbstractString, value::AbstractString, allowed::Set{String})::String
    stripped = strip(String(value))
    stripped in allowed || throw(ApiError("VALIDATION_ERROR", "$name is invalid"; status = 400))
    return stripped
end

function _optional_date(payload, key::AbstractString, default)::Union{Nothing,Date}
    value = _payload_get(payload, key, nothing)
    value === nothing && return default
    value === missing && return nothing
    value isa Date && return value
    parsed = tryparse(Date, strip(String(value)))
    parsed === nothing && throw(ApiError("VALIDATION_ERROR", "$key must be an ISO date"; status = 400))
    return parsed
end

function _optional_json_object(payload, key::AbstractString, default)
    value = _payload_get(payload, key, nothing)
    value === nothing && return default
    value isa AbstractDict || throw(ApiError("VALIDATION_ERROR", "$key must be an object"; status = 400))
    return value
end

function _matches_uuid_filter(row, page::CursorPageRequest, key::String, field::Symbol)::Bool
    !haskey(page.filters, key) && return true
    return row[field] == _uuid_value(page.filters[key])
end

function _inventory_response(row)::NamedTuple
    available = Float64(row[:on_hand_units]) - Float64(row[:reserved_units])
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]), warehouse_id = string(row[:warehouse_id]),
        sku_id = string(row[:sku_id]), on_hand_units = Float64(row[:on_hand_units]),
        reserved_units = Float64(row[:reserved_units]), inbound_units = Float64(row[:inbound_units]),
        safety_stock_units = Float64(row[:safety_stock_units]), available_units = available,
        as_of = string(row[:as_of]), source = String(row[:source]),
    )
end

function _demand_response(row)::NamedTuple
    adjusted = Float64(row[:demand_units]) + Float64(row[:lost_sales_units])
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]), warehouse_id = string(row[:warehouse_id]),
        sku_id = string(row[:sku_id]), period_start = string(row[:period_start]), period_end = string(row[:period_end]),
        demand_units = Float64(row[:demand_units]), lost_sales_units = Float64(row[:lost_sales_units]),
        stockout_adjusted_demand_units = adjusted, source = String(row[:source]),
    )
end

function _lane_response(row)::NamedTuple
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]),
        from_warehouse_id = string(row[:from_warehouse_id]), to_warehouse_id = string(row[:to_warehouse_id]),
        lead_time_days = Int(row[:lead_time_days]), cost_per_unit_cents = Int(row[:cost_per_unit_cents]),
        capacity_units_day = _is_nullish(row[:capacity_units_day]) ? nothing : Float64(row[:capacity_units_day]),
        active = Bool(row[:active]),
    )
end

function _policy_response(row)::NamedTuple
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]), name = String(row[:name]),
        objective = String(row[:objective]), planning_horizon_days = Int(row[:planning_horizon_days]),
        service_level_target = Float64(row[:service_level_target]),
        max_transfer_cost_cents = _is_nullish(row[:max_transfer_cost_cents]) ? nothing : Int(row[:max_transfer_cost_cents]),
        allow_cross_region = Bool(row[:allow_cross_region]),
        frozen_until = _is_nullish(row[:frozen_until]) ? nothing : string(row[:frozen_until]),
        config = row[:config], status = String(row[:status]),
    )
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

function list_demand_history(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["warehouse_id", "sku_id"]))
    rows = fetch_demand_history(store, ctx.tenant_id, page)
    return _page_response(:demand_history, [_demand_response(row) for row in rows], page)
end

function fetch_demand_history(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.demand_history) if row[:tenant_id] == tenant_id]
    rows = [row for row in rows if _matches_uuid_filter(row, page, "warehouse_id", :warehouse_id) && _matches_uuid_filter(row, page, "sku_id", :sku_id)]
    return first(sort(rows; by = row -> (row[:period_start], row[:warehouse_id], row[:sku_id])), min(page.limit, length(rows)))
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

function _lane_payload(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::Dict{Symbol,Any}
    from_id = _uuid_value(_required_text(payload, "from_warehouse_id"))
    to_id = _uuid_value(_required_text(payload, "to_warehouse_id"))
    from_id == to_id && throw(ApiError("VALIDATION_ERROR", "from_warehouse_id and to_warehouse_id must differ"; status = 400))
    fetch_warehouse(store, ctx.tenant_id, from_id) === nothing && throw(ApiError("VALIDATION_ERROR", "from_warehouse_id must belong to tenant"; status = 400))
    fetch_warehouse(store, ctx.tenant_id, to_id) === nothing && throw(ApiError("VALIDATION_ERROR", "to_warehouse_id must belong to tenant"; status = 400))
    lead_time = _validate_nonnegative("lead_time_days", _optional_int(payload, "lead_time_days", 0))
    cost = _validate_nonnegative("cost_per_unit_cents", _optional_int(payload, "cost_per_unit_cents", 0))
    capacity = _optional_nullable_decimal(payload, "capacity_units_day", nothing)
    capacity !== nothing && _validate_nonnegative("capacity_units_day", capacity)
    return Dict{Symbol,Any}(
        :id => uuid4(), :tenant_id => ctx.tenant_id, :from_warehouse_id => from_id, :to_warehouse_id => to_id,
        :lead_time_days => Int(lead_time), :cost_per_unit_cents => Int(cost), :capacity_units_day => capacity,
        :active => something(_optional_bool(payload, "active"), true),
    )
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

function _policy_payload(ctx::TenantContext, payload)::Dict{Symbol,Any}
    horizon = _optional_int(payload, "planning_horizon_days", 0)
    (1 <= horizon <= 180) || throw(ApiError("VALIDATION_ERROR", "planning_horizon_days must be between 1 and 180"; status = 400))
    service = _optional_decimal(payload, "service_level_target", 0)
    (0 < service <= 1) || throw(ApiError("VALIDATION_ERROR", "service_level_target must be greater than zero and at most one"; status = 400))
    max_cost = _payload_get(payload, "max_transfer_cost_cents", nothing)
    parsed_max_cost = max_cost === nothing ? nothing : _validate_nonnegative("max_transfer_cost_cents", max_cost isa Integer ? Int(max_cost) : something(tryparse(Int, strip(String(max_cost))), -1))
    return Dict{Symbol,Any}(
        :id => uuid4(), :tenant_id => ctx.tenant_id, :name => _required_text(payload, "name"),
        :objective => _validate_choice("objective", _required_text(payload, "objective"), POLICY_OBJECTIVES),
        :planning_horizon_days => Int(horizon), :service_level_target => Float64(service),
        :max_transfer_cost_cents => parsed_max_cost, :allow_cross_region => something(_optional_bool(payload, "allow_cross_region"), true),
        :frozen_until => _optional_date(payload, "frozen_until", nothing), :config => _optional_json_object(payload, "config", Dict{String,Any}()),
        :status => _validate_choice("status", _required_text(payload, "status"), POLICY_STATUSES),
    )
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
