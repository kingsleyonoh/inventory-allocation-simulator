function _mean(values::AbstractVector{<:Real})::Float64
    isempty(values) && return 0.0
    return sum(Float64.(values)) / length(values)
end

function _mean_abs2(values::AbstractVector{<:Real})::Float64
    isempty(values) && return 0.0
    return sum(abs2, Float64.(values)) / length(values)
end

function _demand_number(row, key::Symbol)::Float64
    return Float64(get(row, key, 0))
end

function clean_demand_history(rows::AbstractVector)::Vector{NamedTuple}
    return [
        (
            id = string(row[:id]),
            tenant_id = string(row[:tenant_id]),
            warehouse_id = string(row[:warehouse_id]),
            sku_id = string(row[:sku_id]),
            period_start = row[:period_start],
            period_end = row[:period_end],
            observed_units = _demand_number(row, :demand_units),
            lost_sales_units = _demand_number(row, :lost_sales_units),
            adjusted_units = _demand_number(row, :demand_units) + _demand_number(row, :lost_sales_units),
            stockout_adjusted = _demand_number(row, :lost_sales_units) > 0,
        ) for row in rows
    ]
end

function _group_cleaned_demand(cleaned::AbstractVector)
    grouped = Dict{Tuple{String,String},Vector{NamedTuple}}()
    for row in cleaned
        key = (row.warehouse_id, row.sku_id)
        push!(get!(grouped, key, NamedTuple[]), row)
    end
    return grouped
end

function _exp_smoothing(values::Vector{Float64}; alpha::Float64 = 0.35)::Float64
    isempty(values) && return 0.0
    level = first(values)
    for value in values[2:end]
        level = alpha * value + (1 - alpha) * level
    end
    return level
end

function _forecast_summary(key, rows::Vector{NamedTuple})::NamedTuple
    sorted_rows = sort(rows; by = row -> row.period_start)
    adjusted = [row.adjusted_units for row in sorted_rows]
    baseline = _exp_smoothing(adjusted)
    stockouts = count(row -> row.stockout_adjusted, sorted_rows)
    residuals = [value - baseline for value in adjusted]
    variance = length(residuals) > 1 ? _mean_abs2(residuals) : 0.0
    uncertainty = sqrt(max(variance, 0.0)) * (1 + stockouts / max(length(sorted_rows), 1))
    return (
        warehouse_id = key[1],
        sku_id = key[2],
        periods = length(sorted_rows),
        stockout_periods = stockouts,
        baseline_units = baseline,
        mean_adjusted_units = _mean(adjusted),
        observed_mean_units = _mean([row.observed_units for row in sorted_rows]),
        uncertainty_units = uncertainty,
    )
end

function _snapshot_field(obj, key::Symbol, default = nothing)
    obj === nothing && return default
    if obj isa NamedTuple
        return haskey(obj, key) ? getfield(obj, key) : default
    end
    return get(obj, key, get(obj, String(key), default))
end

function _forecast_preview_from_rows(policy_id, policy_name, demand_rows; scenario_count::Int)::NamedTuple
    cleaned = clean_demand_history(demand_rows)
    isempty(cleaned) && throw(ApiError("VALIDATION_ERROR", "demand history is required for forecast preview"; status = 400))
    grouped = _group_cleaned_demand(cleaned)
    forecasts = [_forecast_summary(key, rows) for (key, rows) in grouped]
    return (
        policy_id = string(policy_id),
        policy_name = String(policy_name),
        scenario_count = scenario_count,
        forecasts = sort(forecasts; by = item -> (item.warehouse_id, item.sku_id)),
    )
end

function forecast_preview(
    store::AbstractTenantAdminStore,
    ctx::TenantContext,
    policy_id;
    scenario_count::Int = 100,
)::NamedTuple
    authorize!(ctx, "read", "planning_data")
    parsed_policy_id = _uuid_value(policy_id)
    policy = _snapshot_policy(store, ctx, parsed_policy_id)
    page = CursorPageRequest(SNAPSHOT_MAX_ROWS, nothing, Dict{String,String}())
    return _forecast_preview_from_rows(parsed_policy_id, policy.name, fetch_demand_history(store, ctx.tenant_id, page); scenario_count = scenario_count)
end

function forecast_preview_from_snapshot(snapshot; scenario_count::Int = 100)::NamedTuple
    policy = _snapshot_field(snapshot, :policy)
    policy === nothing && throw(ApiError("VALIDATION_ERROR", "simulation snapshot is missing policy"; status = 400))
    demand_rows = _snapshot_field(snapshot, :demand_history, [])
    return _forecast_preview_from_rows(
        _snapshot_field(policy, :id, ""),
        _snapshot_field(policy, :name, ""),
        demand_rows;
        scenario_count = scenario_count,
    )
end
