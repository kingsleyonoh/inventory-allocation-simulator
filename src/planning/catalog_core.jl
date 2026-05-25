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

function _lane_payload(store::AbstractTenantAdminStore, ctx::TenantContext, payload; current = nothing)::Dict{Symbol,Any}
    from_id = current === nothing ? _uuid_value(_required_text(payload, "from_warehouse_id")) : _uuid_value(something(_optional_text(payload, "from_warehouse_id"), current[:from_warehouse_id]))
    to_id = current === nothing ? _uuid_value(_required_text(payload, "to_warehouse_id")) : _uuid_value(something(_optional_text(payload, "to_warehouse_id"), current[:to_warehouse_id]))
    from_id == to_id && throw(ApiError("VALIDATION_ERROR", "from_warehouse_id and to_warehouse_id must differ"; status = 400))
    fetch_warehouse(store, ctx.tenant_id, from_id) === nothing && throw(ApiError("VALIDATION_ERROR", "from_warehouse_id must belong to tenant"; status = 400))
    fetch_warehouse(store, ctx.tenant_id, to_id) === nothing && throw(ApiError("VALIDATION_ERROR", "to_warehouse_id must belong to tenant"; status = 400))
    lead_time = _validate_nonnegative("lead_time_days", _optional_int(payload, "lead_time_days", current === nothing ? 0 : current[:lead_time_days]))
    cost = _validate_nonnegative("cost_per_unit_cents", _optional_int(payload, "cost_per_unit_cents", current === nothing ? 0 : current[:cost_per_unit_cents]))
    capacity = _optional_nullable_decimal(payload, "capacity_units_day", current === nothing ? nothing : current[:capacity_units_day])
    capacity !== nothing && _validate_nonnegative("capacity_units_day", capacity)
    return Dict{Symbol,Any}(
        :id => current === nothing ? uuid4() : current[:id], :tenant_id => ctx.tenant_id, :from_warehouse_id => from_id, :to_warehouse_id => to_id,
        :lead_time_days => Int(lead_time), :cost_per_unit_cents => Int(cost), :capacity_units_day => capacity,
        :active => something(_optional_bool(payload, "active"), current === nothing ? true : current[:active]),
    )
end

function _policy_payload(ctx::TenantContext, payload; current = nothing)::Dict{Symbol,Any}
    horizon = _optional_int(payload, "planning_horizon_days", current === nothing ? 0 : current[:planning_horizon_days])
    (1 <= horizon <= 180) || throw(ApiError("VALIDATION_ERROR", "planning_horizon_days must be between 1 and 180"; status = 400))
    service = _optional_decimal(payload, "service_level_target", current === nothing ? 0 : current[:service_level_target])
    (0 < service <= 1) || throw(ApiError("VALIDATION_ERROR", "service_level_target must be greater than zero and at most one"; status = 400))
    max_cost = _payload_get(payload, "max_transfer_cost_cents", nothing)
    parsed_max_cost = max_cost === nothing ? (current === nothing ? nothing : current[:max_transfer_cost_cents]) : _validate_nonnegative("max_transfer_cost_cents", max_cost isa Integer ? Int(max_cost) : something(tryparse(Int, strip(String(max_cost))), -1))
    return Dict{Symbol,Any}(
        :id => current === nothing ? uuid4() : current[:id], :tenant_id => ctx.tenant_id,
        :name => current === nothing ? _required_text(payload, "name") : something(_optional_text(payload, "name"), current[:name]),
        :objective => _validate_choice("objective", current === nothing ? _required_text(payload, "objective") : something(_optional_text(payload, "objective"), current[:objective]), POLICY_OBJECTIVES),
        :planning_horizon_days => Int(horizon), :service_level_target => Float64(service),
        :max_transfer_cost_cents => parsed_max_cost, :allow_cross_region => something(_optional_bool(payload, "allow_cross_region"), current === nothing ? true : current[:allow_cross_region]),
        :frozen_until => _optional_date(payload, "frozen_until", current === nothing ? nothing : current[:frozen_until]), :config => _optional_json_object(payload, "config", current === nothing ? Dict{String,Any}() : current[:config]),
        :status => _validate_choice("status", current === nothing ? _required_text(payload, "status") : something(_optional_text(payload, "status"), current[:status]), POLICY_STATUSES),
    )
end
