using JuMP
using HiGHS

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

function _recommendation_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        simulation_run_id = string(row[:simulation_run_id]),
        from_warehouse_id = string(row[:from_warehouse_id]),
        to_warehouse_id = string(row[:to_warehouse_id]),
        sku_id = string(row[:sku_id]),
        transfer_units = Float64(row[:transfer_units]),
        expected_stockout_reduction_units = Float64(row[:expected_stockout_reduction_units]),
        expected_margin_gain_cents = Int(row[:expected_margin_gain_cents]),
        transfer_cost_cents = Int(row[:transfer_cost_cents]),
        net_value_cents = Int(row[:net_value_cents]),
        confidence_score = Float64(row[:confidence_score]),
        explanation = row[:explanation],
        status = String(row[:status]),
    )
end

function persist_allocation_recommendation_create!(store::MemoryTenantAdminStore, row)
    store.allocation_recommendations[row[:id]] = row
    return row
end

function fetch_allocation_recommendations(store::MemoryTenantAdminStore, tenant_id::UUID, run_id::UUID)
    rows = [row for row in values(store.allocation_recommendations) if row[:tenant_id] == tenant_id && row[:simulation_run_id] == run_id]
    return sort(rows; by = row -> row[:created_at])
end

function persist_allocation_recommendation_create!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO allocation_recommendations (id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13::jsonb, \$14)
    """, [string(row[:id]), string(row[:tenant_id]), string(row[:simulation_run_id]), string(row[:from_warehouse_id]), string(row[:to_warehouse_id]), string(row[:sku_id]), row[:transfer_units], row[:expected_stockout_reduction_units], row[:expected_margin_gain_cents], row[:transfer_cost_cents], row[:net_value_cents], row[:confidence_score], JSON3.write(row[:explanation]), row[:status]])
    return row
end

function _sql_recommendation_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :simulation_run_id => UUID(String(row[3])),
        :from_warehouse_id => UUID(String(row[4])), :to_warehouse_id => UUID(String(row[5])), :sku_id => UUID(String(row[6])),
        :transfer_units => Float64(row[7]), :expected_stockout_reduction_units => Float64(row[8]),
        :expected_margin_gain_cents => Int(row[9]), :transfer_cost_cents => Int(row[10]), :net_value_cents => Int(row[11]),
        :confidence_score => Float64(row[12]), :explanation => JSON3.read(String(row[13])), :status => String(row[14]),
        :created_at => row[15], :updated_at => row[16],
    )
end

function fetch_allocation_recommendations(store::SqlTenantAdminStore, tenant_id::UUID, run_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status, created_at, updated_at
        FROM allocation_recommendations
        WHERE tenant_id = \$1 AND simulation_run_id = \$2
        ORDER BY created_at
    """, [string(tenant_id), string(run_id)])
    return [_sql_recommendation_row(row) for row in result]
end

function solve_allocation_model(snapshot, scenarios; config::AllocationSolverConfig = AllocationSolverConfig())::NamedTuple
    config.timeout_seconds <= 0 && return _failed_solver_result("TIME_LIMIT", "solver timeout reached before optimization started", snapshot)

    policy = _solver_field(snapshot, :policy)
    objective = _solver_string(policy, :objective, "balanced")
    horizon = max(_solver_int(policy, :planning_horizon_days, 1), 1)
    service_level = _solver_float(policy, :service_level_target, 0.95)
    max_cost = _solver_field(policy, :max_transfer_cost_cents, nothing)
    allow_cross_region = _solver_bool(policy, :allow_cross_region, true)

    warehouses = _active_items(_solver_items(snapshot, :warehouses))
    skus = _active_items(_solver_items(snapshot, :skus))
    lanes = _active_items(_solver_items(snapshot, :transfer_lanes))
    inventory = _solver_items(snapshot, :inventory_positions)
    demands = _demand_by_node(scenarios)

    warehouse_by_id = Dict(_solver_string(item, :id) => item for item in warehouses)
    sku_by_id = Dict(_solver_string(item, :id) => item for item in skus)
    active_sku_ids = Set(keys(sku_by_id))
    inv_by_node = Dict((_solver_string(item, :warehouse_id), _solver_string(item, :sku_id)) => item for item in inventory if _solver_string(item, :sku_id) in active_sku_ids)
    nodes = collect(keys(inv_by_node))
    for key in keys(demands)
        key[2] in active_sku_ids && !haskey(inv_by_node, key) && push!(nodes, key)
    end
    nodes = unique(nodes)

    blocked_by_region = false
    allowed_lanes = []
    for lane in lanes
        from_id = _solver_string(lane, :from_warehouse_id)
        to_id = _solver_string(lane, :to_warehouse_id)
        haskey(warehouse_by_id, from_id) || continue
        haskey(warehouse_by_id, to_id) || continue
        if !allow_cross_region && _solver_string(warehouse_by_id[from_id], :region) != _solver_string(warehouse_by_id[to_id], :region)
            blocked_by_region = true
            continue
        end
        push!(allowed_lanes, lane)
    end
    for lane in allowed_lanes, sku in skus
        sku_id = _solver_string(sku, :id)
        push!(nodes, (_solver_string(lane, :from_warehouse_id), sku_id))
        push!(nodes, (_solver_string(lane, :to_warehouse_id), sku_id))
    end
    nodes = unique(nodes)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    set_time_limit_sec(model, config.timeout_seconds)
    set_optimizer_attribute(model, "mip_rel_gap", config.max_gap)

    lane_sku_keys = [(i, _solver_string(sku, :id)) for i in eachindex(allowed_lanes) for sku in skus]
    @variable(model, transfer[lane_sku_keys] >= 0)
    @variable(model, unmet[nodes] >= 0)

    available = Dict{Tuple{String,String},Float64}()
    safety = Dict{Tuple{String,String},Float64}()
    for node in nodes
        inv = get(inv_by_node, node, nothing)
        available[node] = inv === nothing ? 0.0 : _solver_float(inv, :available_units, _solver_float(inv, :on_hand_units) - _solver_float(inv, :reserved_units) + _solver_float(inv, :inbound_units))
        safety[node] = inv === nothing ? 0.0 : _solver_float(inv, :safety_stock_units)
    end
    if isempty(allowed_lanes) && blocked_by_region && any(max(get(demands, node, 0.0) - get(available, node, 0.0), 0.0) > 0 for node in nodes)
        return _failed_solver_result("INFEASIBLE", "region constraint blocks all feasible transfer lanes", snapshot)
    end

    incoming(node) = sum(transfer[(idx, sku_id)] for (idx, sku_id) in lane_sku_keys if sku_id == node[2] && _solver_string(allowed_lanes[idx], :to_warehouse_id) == node[1]; init = 0.0)
    outgoing(node) = sum(transfer[(idx, sku_id)] for (idx, sku_id) in lane_sku_keys if sku_id == node[2] && _solver_string(allowed_lanes[idx], :from_warehouse_id) == node[1]; init = 0.0)
    ending(node) = available[node] + incoming(node) - outgoing(node)

    for (idx, lane) in enumerate(allowed_lanes)
        capacity = _solver_field(lane, :capacity_units_day, nothing)
        if capacity !== nothing
            for sku in skus
                key = (idx, _solver_string(sku, :id))
                @constraint(model, transfer[key] <= Float64(capacity) * horizon)
            end
        end
    end

    has_incoming_lane(node) = any(sku_id == node[2] && _solver_string(allowed_lanes[idx], :to_warehouse_id) == node[1] for (idx, sku_id) in lane_sku_keys)
    for node in nodes
        @constraint(model, outgoing(node) <= max(available[node] - safety[node], 0.0))
        demand = get(demands, node, 0.0)
        @constraint(model, ending(node) + unmet[node] >= demand)
        if has_incoming_lane(node)
            @constraint(model, ending(node) >= safety[node])
            @constraint(model, unmet[node] <= (1.0 - service_level) * demand)
        end
    end

    for wh in warehouses
        wh_id = _solver_string(wh, :id)
        capacity = _solver_float(wh, :capacity_units)
        @constraint(model, sum(ending(node) * _solver_float(get(sku_by_id, node[2], Dict{String,Any}()), :unit_volume, 1.0) for node in nodes if node[1] == wh_id; init = 0.0) <= capacity)
    end

    transfer_cost_expr = sum(transfer[(idx, sku_id)] * _solver_int(allowed_lanes[idx], :cost_per_unit_cents) for (idx, sku_id) in lane_sku_keys; init = 0.0)
    if max_cost !== nothing
        @constraint(model, transfer_cost_expr <= Float64(max_cost))
    end

    benefit_terms = []
    for node in nodes
        sku = get(sku_by_id, node[2], nothing)
        sku === nothing && continue
        shortage_before = max(get(demands, node, 0.0) - available[node], 0.0)
        coef = if objective == "maximize_margin"
            _solver_int(sku, :unit_margin_cents)
        elseif objective == "balanced"
            _solver_int(sku, :stockout_cost_cents) + _solver_int(sku, :unit_margin_cents)
        else
            _solver_int(sku, :stockout_cost_cents)
        end
        push!(benefit_terms, coef * (shortage_before - unmet[node]))
    end
    holding_expr = sum(incoming(node) * _solver_int(get(sku_by_id, node[2], Dict{String,Any}()), :holding_cost_cents, 0) for node in nodes; init = 0.0)
    @objective(model, Max, sum(benefit_terms; init = 0.0) - transfer_cost_expr - holding_expr)
    optimize!(model)

    status = string(termination_status(model))
    primal = primal_status(model)
    has_incumbent = primal == JuMP.MOI.FEASIBLE_POINT
    gap = try
        JuMP.MOI.get(model, JuMP.MOI.RelativeGap())
    catch
        status in _SOLVER_SUCCESS_STATUSES ? 0.0 : nothing
    end
    decision = solver_outcome_decision(status, gap, has_incumbent, config.max_gap)
    decision.accepted || return _failed_solver_result(status, "solver did not produce an acceptable solution ($(decision.reason))", snapshot)

    recs = NamedTuple[]
    incoming_reduction_used = Dict{Tuple{String,String},Float64}()
    for (idx, sku_id) in lane_sku_keys
        units = value(transfer[(idx, sku_id)])
        units + 1e-6 < config.min_transfer_units && continue
        lane = allowed_lanes[idx]
        from_id = _solver_string(lane, :from_warehouse_id)
        to_id = _solver_string(lane, :to_warehouse_id)
        dest = (to_id, sku_id)
        source = (from_id, sku_id)
        demand = get(demands, dest, 0.0)
        shortage_before = max(demand - get(available, dest, 0.0), 0.0)
        already_used = get(incoming_reduction_used, dest, 0.0)
        reduction = max(min(units, shortage_before - already_used), 0.0)
        incoming_reduction_used[dest] = already_used + reduction
        sku = sku_by_id[sku_id]
        expected_benefit = _objective_benefit_cents(objective, sku, reduction)
        margin_gain = objective in ("maximize_margin", "balanced") ? round(Int, reduction * _solver_int(sku, :unit_margin_cents)) : 0
        if objective == "maximize_margin"
            expected_benefit = 0
        elseif objective == "balanced"
            expected_benefit = round(Int, reduction * _solver_int(sku, :stockout_cost_cents))
        end
        transfer_cost = round(Int, units * _solver_int(lane, :cost_per_unit_cents))
        holding_cost = round(Int, units * _solver_int(sku, :holding_cost_cents, 0))
        net = recommendation_net_value(
            expected_benefit_cents = expected_benefit,
            expected_margin_gain_cents = margin_gain,
            transfer_cost_cents = transfer_cost,
            holding_cost_cents = holding_cost,
        )
        source_end = value(ending(source))
        dest_unmet = value(unmet[dest])
        allowed_unmet = (1.0 - service_level) * demand
        lane_cap = _solver_field(lane, :capacity_units_day, nothing) === nothing ? Inf : Float64(_solver_field(lane, :capacity_units_day)) * horizon
        explanation = Dict{String,Any}(
            "objective" => objective,
            "binding_constraints" => _binding_constraints(units, lane_cap, source_end, get(safety, source, 0.0), dest_unmet, allowed_unmet),
            "scenario_sensitivity" => Dict{String,Any}(
                "scenario_count" => length(scenarios),
                "expected_demand_units" => demand,
                "shortage_before_units" => shortage_before,
                "unmet_after_units" => round(dest_unmet; digits = 4),
            ),
            "accepted_tradeoffs" => ["transfer_cost", "sender_safety_stock", "receiver_service_level"],
            "net_value" => Dict{String,Any}(
                "expected_benefit_cents" => net.expected_benefit_cents,
                "expected_margin_gain_cents" => net.expected_margin_gain_cents,
                "transfer_cost_cents" => net.transfer_cost_cents,
                "holding_cost_cents" => net.holding_cost_cents,
                "net_value_cents" => net.net_value_cents,
            ),
            "solver" => Dict{String,Any}("status" => status, "optimality_gap" => decision.gap),
        )
        push!(recs, (
            tenant_id = _solver_string(snapshot, :tenant_id),
            from_warehouse_id = from_id,
            to_warehouse_id = to_id,
            sku_id = sku_id,
            transfer_units = round(units; digits = 4),
            expected_stockout_reduction_units = round(reduction; digits = 4),
            expected_margin_gain_cents = net.expected_margin_gain_cents,
            transfer_cost_cents = net.transfer_cost_cents,
            net_value_cents = net.net_value_cents,
            confidence_score = _confidence_score(reduction, demand, scenarios),
            explanation = explanation,
            status = "proposed",
        ))
    end

    isempty(recs) && return _empty_model_result(status, decision.gap, snapshot)
    return (
        status = "optimal",
        solver_status = status,
        optimality_gap = decision.gap,
        recommendations = recs,
        diagnostics = Dict{String,Any}("solver_status" => status, "optimality_gap" => decision.gap, "constraint_report" => _constraint_report(snapshot)),
    )
end

function generate_allocation_recommendations!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext,
    simulation_run_id;
    config::AllocationSolverConfig = AllocationSolverConfig(),
)::Vector{NamedTuple}
    authorize!(ctx, "run_cancel", "simulation")
    run = fetch_simulation_run(store, ctx.tenant_id, _uuid_value(simulation_run_id))
    run === nothing && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
    existing = fetch_allocation_recommendations(store, ctx.tenant_id, run[:id])
    !isempty(existing) && return [_recommendation_response(row) for row in existing]
    scenarios = [_scenario_response(row) for row in fetch_demand_scenarios(store, ctx.tenant_id, run[:id])]
    result = solve_allocation_model(run[:input_snapshot], scenarios; config = config)
    result.status == "optimal" || throw(ApiError("SOLVER_FAILED", result.diagnostics["message"]; details = [result.diagnostics], status = 422))
    now = Dates.now()
    rows = Dict{Symbol,Any}[]
    for rec in result.recommendations
        row = Dict{Symbol,Any}(
            :id => uuid4(),
            :tenant_id => ctx.tenant_id,
            :simulation_run_id => run[:id],
            :from_warehouse_id => UUID(rec.from_warehouse_id),
            :to_warehouse_id => UUID(rec.to_warehouse_id),
            :sku_id => UUID(rec.sku_id),
            :transfer_units => rec.transfer_units,
            :expected_stockout_reduction_units => rec.expected_stockout_reduction_units,
            :expected_margin_gain_cents => rec.expected_margin_gain_cents,
            :transfer_cost_cents => rec.transfer_cost_cents,
            :net_value_cents => rec.net_value_cents,
            :confidence_score => rec.confidence_score,
            :explanation => rec.explanation,
            :status => rec.status,
            :created_at => now,
            :updated_at => now,
        )
        persist_allocation_recommendation_create!(store, row)
        push!(rows, row)
    end
    return [_recommendation_response(row) for row in rows]
end
