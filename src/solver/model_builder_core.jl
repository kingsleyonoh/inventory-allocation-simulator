struct AllocationSolverConfig
    timeout_seconds::Float64
    max_gap::Float64
    min_transfer_units::Float64
end

AllocationSolverConfig(; timeout_seconds::Real = 120.0, max_gap::Real = 0.05, min_transfer_units::Real = 1.0) =
    AllocationSolverConfig(Float64(timeout_seconds), Float64(max_gap), Float64(min_transfer_units))

const _SOLVER_SUCCESS_STATUSES = Set(["OPTIMAL", "LOCALLY_SOLVED", "ALMOST_OPTIMAL"])

function solver_outcome_decision(status::AbstractString, gap, has_incumbent::Bool, max_gap::Real)::NamedTuple
    normalized = uppercase(String(status))
    gap_value = gap === nothing ? Inf : Float64(gap)
    if normalized in _SOLVER_SUCCESS_STATUSES
        return (accepted = true, reason = "OPTIMAL", gap = gap_value)
    end
    if normalized == "TIME_LIMIT" && has_incumbent && gap_value <= Float64(max_gap)
        return (accepted = true, reason = "TIME_LIMIT_GAP_ACCEPTED", gap = gap_value)
    end
    if normalized == "TIME_LIMIT" && has_incumbent
        return (accepted = false, reason = "TIME_LIMIT_GAP_EXCEEDED", gap = gap_value)
    end
    return (accepted = false, reason = normalized, gap = gap_value)
end

function _solver_field(obj, key::Symbol, default = nothing)
    obj === nothing && return default
    obj isa NamedTuple && return haskey(obj, key) ? getfield(obj, key) : default
    obj isa AbstractDict && return get(obj, key, get(obj, String(key), default))
    return hasproperty(obj, key) ? getproperty(obj, key) : default
end

_solver_string(obj, key::Symbol, default = "") = String(_solver_field(obj, key, default))
_solver_float(obj, key::Symbol, default = 0.0) = Float64(_solver_field(obj, key, default))
_solver_int(obj, key::Symbol, default = 0) = Int(round(Float64(_solver_field(obj, key, default))))
_solver_bool(obj, key::Symbol, default = false) = Bool(_solver_field(obj, key, default))

function _solver_items(snapshot, key::Symbol)::Vector{Any}
    value = _solver_field(snapshot, key, [])
    return Any[item for item in value]
end

function _active_items(items)
    return [item for item in items if _solver_bool(item, :active, true)]
end

function _demand_by_node(scenarios)::Dict{Tuple{String,String},Float64}
    demand = Dict{Tuple{String,String},Float64}()
    for scenario in scenarios
        weight = _solver_float(scenario, :probability_weight, 1.0)
        payload = _solver_field(scenario, :demand_payload, Dict{String,Any}())
        demands = _solver_field(payload, :demands, [])
        for item in demands
            key = (_solver_string(item, :warehouse_id), _solver_string(item, :sku_id))
            demand[key] = get(demand, key, 0.0) + weight * _solver_float(item, :demand_units)
        end
    end
    return demand
end

function _constraint_report(snapshot)::Vector{String}
    policy = _solver_field(snapshot, :policy)
    report = String["service_level_target may exceed stock available after lane, safety-stock, region, capacity, and cost constraints"]
    if _solver_field(policy, :max_transfer_cost_cents, nothing) !== nothing
        push!(report, "max_transfer_cost_cents=$(Int(_solver_field(policy, :max_transfer_cost_cents)))")
    end
    !_solver_bool(policy, :allow_cross_region, true) && push!(report, "region constraint blocks cross-region lanes")
    push!(report, "sender safety stock and receiver service-level constraints remain hard requirements")
    return report
end

function _failed_solver_result(status::AbstractString, message::AbstractString, snapshot)::NamedTuple
    return (
        status = "failed",
        solver_status = String(status),
        optimality_gap = nothing,
        recommendations = NamedTuple[],
        diagnostics = Dict{String,Any}(
            "solver_status" => String(status),
            "message" => String(message),
            "constraint_report" => _constraint_report(snapshot),
        ),
    )
end

function _objective_benefit_cents(objective::AbstractString, sku, reduction::Real)::Int
    units = Float64(reduction)
    if objective == "maximize_margin"
        return round(Int, units * _solver_int(sku, :unit_margin_cents))
    elseif objective == "balanced"
        return round(Int, units * (_solver_int(sku, :stockout_cost_cents) + _solver_int(sku, :unit_margin_cents)))
    end
    return round(Int, units * _solver_int(sku, :stockout_cost_cents))
end

function recommendation_net_value(; expected_benefit_cents::Integer, expected_margin_gain_cents::Integer = 0, transfer_cost_cents::Integer, holding_cost_cents::Integer = 0)::NamedTuple
    net = Int(expected_benefit_cents) + Int(expected_margin_gain_cents) - Int(transfer_cost_cents) - Int(holding_cost_cents)
    return (
        expected_benefit_cents = Int(expected_benefit_cents),
        expected_margin_gain_cents = Int(expected_margin_gain_cents),
        transfer_cost_cents = Int(transfer_cost_cents),
        holding_cost_cents = Int(holding_cost_cents),
        net_value_cents = net,
    )
end

function _confidence_score(reduction::Real, demand::Real, scenarios)::Float64
    demand <= 0 && return 0.0
    scenario_count = max(length(scenarios), 1)
    coverage = min(Float64(reduction) / Float64(demand), 1.0)
    return round(clamp(0.5 + 0.4 * coverage + 0.1 / scenario_count, 0.0, 1.0); digits = 4)
end

function _binding_constraints(x_value, lane_limit, source_end, source_safety, dest_unmet, allowed_unmet)
    constraints = String[]
    abs(x_value - lane_limit) <= 1e-4 && push!(constraints, "lane_capacity")
    abs(source_end - source_safety) <= 1e-4 && push!(constraints, "sender_safety_stock")
    abs(dest_unmet - allowed_unmet) <= 1e-4 && push!(constraints, "receiver_service_level")
    isempty(constraints) && push!(constraints, "objective_tradeoff")
    return constraints
end

function _empty_model_result(status::AbstractString, gap, snapshot)::NamedTuple
    return (
        status = "optimal",
        solver_status = String(status),
        optimality_gap = gap,
        recommendations = NamedTuple[],
        diagnostics = Dict{String,Any}(
            "solver_status" => String(status),
            "message" => "No transfer recommendation met MIN_TRANSFER_UNITS",
            "constraint_report" => _constraint_report(snapshot),
        ),
    )
end
