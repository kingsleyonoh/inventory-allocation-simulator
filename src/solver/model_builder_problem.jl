function _solver_context(snapshot, scenarios)::NamedTuple
    policy = _solver_field(snapshot, :policy)
    skus = _active_items(_solver_items(snapshot, :skus))
    inventory = _solver_items(snapshot, :inventory_positions)
    sku_by_id = Dict(_solver_string(item, :id) => item for item in skus)
    active_sku_ids = Set(keys(sku_by_id))
    inv_by_node = Dict(
        (_solver_string(item, :warehouse_id), _solver_string(item, :sku_id)) => item
        for item in inventory if _solver_string(item, :sku_id) in active_sku_ids
    )
    return (
        policy = policy,
        objective = _solver_string(policy, :objective, "balanced"),
        horizon = max(_solver_int(policy, :planning_horizon_days, 1), 1),
        service_level = _solver_float(policy, :service_level_target, 0.95),
        max_cost = _solver_field(policy, :max_transfer_cost_cents, nothing),
        allow_cross_region = _solver_bool(policy, :allow_cross_region, true),
        warehouses = _active_items(_solver_items(snapshot, :warehouses)),
        skus = skus,
        lanes = _active_items(_solver_items(snapshot, :transfer_lanes)),
        demands = _demand_by_node(scenarios),
        sku_by_id = sku_by_id,
        inv_by_node = inv_by_node,
    )
end

function _solver_nodes_and_lanes(ctx)::NamedTuple
    warehouse_by_id = Dict(_solver_string(item, :id) => item for item in ctx.warehouses)
    nodes = collect(keys(ctx.inv_by_node))
    for key in keys(ctx.demands)
        haskey(ctx.sku_by_id, key[2]) && !haskey(ctx.inv_by_node, key) && push!(nodes, key)
    end
    blocked_by_region = false
    allowed_lanes = Any[]
    for lane in ctx.lanes
        from_id = _solver_string(lane, :from_warehouse_id)
        to_id = _solver_string(lane, :to_warehouse_id)
        haskey(warehouse_by_id, from_id) || continue
        haskey(warehouse_by_id, to_id) || continue
        if !ctx.allow_cross_region && _solver_string(warehouse_by_id[from_id], :region) != _solver_string(warehouse_by_id[to_id], :region)
            blocked_by_region = true
            continue
        end
        push!(allowed_lanes, lane)
    end
    for lane in allowed_lanes, sku in ctx.skus
        push!(nodes, (_solver_string(lane, :from_warehouse_id), _solver_string(sku, :id)))
        push!(nodes, (_solver_string(lane, :to_warehouse_id), _solver_string(sku, :id)))
    end
    return merge(ctx, (warehouse_by_id = warehouse_by_id, nodes = unique(nodes), allowed_lanes = allowed_lanes, blocked_by_region = blocked_by_region))
end

function _region_blocked_with_demand(problem)::Bool
    return isempty(problem.allowed_lanes) && problem.blocked_by_region && any(
        max(get(problem.demands, node, 0.0) - get(problem.available, node, 0.0), 0.0) > 0
        for node in problem.nodes
    )
end

function _solver_stock_maps(nodes, inv_by_node)::NamedTuple
    available = Dict{Tuple{String,String},Float64}()
    safety = Dict{Tuple{String,String},Float64}()
    for node in nodes
        inv = get(inv_by_node, node, nothing)
        available[node] = inv === nothing ? 0.0 : _solver_float(inv, :available_units, _solver_float(inv, :on_hand_units) - _solver_float(inv, :reserved_units) + _solver_float(inv, :inbound_units))
        safety[node] = inv === nothing ? 0.0 : _solver_float(inv, :safety_stock_units)
    end
    return (available = available, safety = safety)
end

function _initialize_solver_model(config::AllocationSolverConfig, lane_sku_keys, nodes)::NamedTuple
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    set_time_limit_sec(model, config.timeout_seconds)
    set_optimizer_attribute(model, "mip_rel_gap", config.max_gap)
    @variable(model, transfer[lane_sku_keys] >= 0)
    @variable(model, unmet[nodes] >= 0)
    return (model = model, transfer = transfer, unmet = unmet)
end

function _flow_functions(transfer, lane_sku_keys, allowed_lanes, available)::NamedTuple
    incoming(node) = sum(transfer[(idx, sku_id)] for (idx, sku_id) in lane_sku_keys if sku_id == node[2] && _solver_string(allowed_lanes[idx], :to_warehouse_id) == node[1]; init = 0.0)
    outgoing(node) = sum(transfer[(idx, sku_id)] for (idx, sku_id) in lane_sku_keys if sku_id == node[2] && _solver_string(allowed_lanes[idx], :from_warehouse_id) == node[1]; init = 0.0)
    ending(node) = available[node] + incoming(node) - outgoing(node)
    return (incoming = incoming, outgoing = outgoing, ending = ending)
end

function _build_solver_problem(snapshot, scenarios, config::AllocationSolverConfig)::NamedTuple
    ctx = _solver_nodes_and_lanes(_solver_context(snapshot, scenarios))
    stock = _solver_stock_maps(ctx.nodes, ctx.inv_by_node)
    lane_sku_keys = [(i, _solver_string(sku, :id)) for i in eachindex(ctx.allowed_lanes) for sku in ctx.skus]
    variables = _initialize_solver_model(config, lane_sku_keys, ctx.nodes)
    flows = _flow_functions(variables.transfer, lane_sku_keys, ctx.allowed_lanes, stock.available)
    return merge(ctx, stock, variables, (lane_sku_keys = lane_sku_keys, flows = flows))
end

function _add_lane_capacity_constraints!(problem)
    for (idx, lane) in enumerate(problem.allowed_lanes)
        capacity = _solver_field(lane, :capacity_units_day, nothing)
        capacity === nothing && continue
        for sku in problem.skus
            @constraint(problem.model, problem.transfer[(idx, _solver_string(sku, :id))] <= Float64(capacity) * problem.horizon)
        end
    end
end

function _add_node_constraints!(problem)
    has_incoming_lane(node) = any(sku_id == node[2] && _solver_string(problem.allowed_lanes[idx], :to_warehouse_id) == node[1] for (idx, sku_id) in problem.lane_sku_keys)
    for node in problem.nodes
        demand = get(problem.demands, node, 0.0)
        @constraint(problem.model, problem.flows.outgoing(node) <= max(problem.available[node] - problem.safety[node], 0.0))
        @constraint(problem.model, problem.flows.ending(node) + problem.unmet[node] >= demand)
        if has_incoming_lane(node)
            @constraint(problem.model, problem.flows.ending(node) >= problem.safety[node])
            @constraint(problem.model, problem.unmet[node] <= (1.0 - problem.service_level) * demand)
        end
    end
end

function _add_warehouse_capacity_constraints!(problem)
    for wh in problem.warehouses
        wh_id = _solver_string(wh, :id)
        volume(node) = _solver_float(get(problem.sku_by_id, node[2], Dict{String,Any}()), :unit_volume, 1.0)
        @constraint(problem.model, sum(problem.flows.ending(node) * volume(node) for node in problem.nodes if node[1] == wh_id; init = 0.0) <= _solver_float(wh, :capacity_units))
    end
end

function _transfer_cost_expr(problem)
    return sum(problem.transfer[(idx, sku_id)] * _solver_int(problem.allowed_lanes[idx], :cost_per_unit_cents) for (idx, sku_id) in problem.lane_sku_keys; init = 0.0)
end

function _benefit_terms(problem)
    terms = Any[]
    for node in problem.nodes
        sku = get(problem.sku_by_id, node[2], nothing)
        sku === nothing && continue
        shortage_before = max(get(problem.demands, node, 0.0) - problem.available[node], 0.0)
        coef = problem.objective == "maximize_margin" ? _solver_int(sku, :unit_margin_cents) : _objective_benefit_cents(problem.objective, sku, 1)
        push!(terms, coef * (shortage_before - problem.unmet[node]))
    end
    return terms
end

function _set_solver_objective!(problem, transfer_cost_expr)
    holding_expr = sum(
        problem.flows.incoming(node) * _solver_int(get(problem.sku_by_id, node[2], Dict{String,Any}()), :holding_cost_cents, 0)
        for node in problem.nodes; init = 0.0
    )
    @objective(problem.model, Max, sum(_benefit_terms(problem); init = 0.0) - transfer_cost_expr - holding_expr)
end

function _add_solver_constraints_and_objective!(problem)
    _add_lane_capacity_constraints!(problem)
    _add_node_constraints!(problem)
    _add_warehouse_capacity_constraints!(problem)
    transfer_cost_expr = _transfer_cost_expr(problem)
    problem.max_cost !== nothing && @constraint(problem.model, transfer_cost_expr <= Float64(problem.max_cost))
    _set_solver_objective!(problem, transfer_cost_expr)
end

function _solver_decision(model, config::AllocationSolverConfig)::NamedTuple
    status = string(termination_status(model))
    primal = primal_status(model)
    gap = try
        JuMP.MOI.get(model, JuMP.MOI.RelativeGap())
    catch
        status in _SOLVER_SUCCESS_STATUSES ? 0.0 : nothing
    end
    decision = solver_outcome_decision(status, gap, primal == JuMP.MOI.FEASIBLE_POINT, config.max_gap)
    return (status = status, decision = decision)
end
