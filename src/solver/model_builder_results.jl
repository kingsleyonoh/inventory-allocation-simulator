function _solver_reduction_state(problem, idx::Integer, sku_id::AbstractString, incoming_reduction_used)::NamedTuple
    lane = problem.allowed_lanes[idx]
    from_id = _solver_string(lane, :from_warehouse_id)
    to_id = _solver_string(lane, :to_warehouse_id)
    units = value(problem.transfer[(idx, sku_id)])
    dest = (to_id, String(sku_id))
    demand = get(problem.demands, dest, 0.0)
    shortage_before = max(demand - get(problem.available, dest, 0.0), 0.0)
    already_used = get(incoming_reduction_used, dest, 0.0)
    reduction = max(min(units, shortage_before - already_used), 0.0)
    incoming_reduction_used[dest] = already_used + reduction
    return (lane = lane, from_id = from_id, to_id = to_id, units = units, dest = dest, source = (from_id, String(sku_id)), demand = demand, shortage_before = shortage_before, reduction = reduction)
end

function _solver_value_metrics(problem, state, sku)::NamedTuple
    expected_benefit = _objective_benefit_cents(problem.objective, sku, state.reduction)
    margin_gain = problem.objective in ("maximize_margin", "balanced") ? round(Int, state.reduction * _solver_int(sku, :unit_margin_cents)) : 0
    if problem.objective == "maximize_margin"
        expected_benefit = 0
    elseif problem.objective == "balanced"
        expected_benefit = round(Int, state.reduction * _solver_int(sku, :stockout_cost_cents))
    end
    return recommendation_net_value(
        expected_benefit_cents = expected_benefit,
        expected_margin_gain_cents = margin_gain,
        transfer_cost_cents = round(Int, state.units * _solver_int(state.lane, :cost_per_unit_cents)),
        holding_cost_cents = round(Int, state.units * _solver_int(sku, :holding_cost_cents, 0)),
    )
end

function _solver_explanation(problem, state, net, scenarios, status::AbstractString, gap)::Dict{String,Any}
    source_end = value(problem.flows.ending(state.source))
    dest_unmet = value(problem.unmet[state.dest])
    allowed_unmet = (1.0 - problem.service_level) * state.demand
    lane_cap = _solver_field(state.lane, :capacity_units_day, nothing) === nothing ? Inf : Float64(_solver_field(state.lane, :capacity_units_day)) * problem.horizon
    return Dict{String,Any}(
        "objective" => problem.objective,
        "binding_constraints" => _binding_constraints(state.units, lane_cap, source_end, get(problem.safety, state.source, 0.0), dest_unmet, allowed_unmet),
        "scenario_sensitivity" => Dict{String,Any}("scenario_count" => length(scenarios), "expected_demand_units" => state.demand, "shortage_before_units" => state.shortage_before, "unmet_after_units" => round(dest_unmet; digits = 4)),
        "accepted_tradeoffs" => ["transfer_cost", "sender_safety_stock", "receiver_service_level"],
        "net_value" => Dict{String,Any}("expected_benefit_cents" => net.expected_benefit_cents, "expected_margin_gain_cents" => net.expected_margin_gain_cents, "transfer_cost_cents" => net.transfer_cost_cents, "holding_cost_cents" => net.holding_cost_cents, "net_value_cents" => net.net_value_cents),
        "solver" => Dict{String,Any}("status" => status, "optimality_gap" => gap),
    )
end

function _recommendation_tuple(snapshot, problem, state, net, explanation, sku_id::AbstractString, scenarios)::NamedTuple
    return (
        tenant_id = _solver_string(snapshot, :tenant_id),
        from_warehouse_id = state.from_id,
        to_warehouse_id = state.to_id,
        sku_id = String(sku_id),
        transfer_units = round(state.units; digits = 4),
        expected_stockout_reduction_units = round(state.reduction; digits = 4),
        expected_margin_gain_cents = net.expected_margin_gain_cents,
        transfer_cost_cents = net.transfer_cost_cents,
        net_value_cents = net.net_value_cents,
        confidence_score = _confidence_score(state.reduction, state.demand, scenarios),
        explanation = explanation,
        status = "proposed",
    )
end

function _allocation_recommendations(snapshot, problem, scenarios, metadata)::Vector{NamedTuple}
    recs = NamedTuple[]
    incoming_reduction_used = Dict{Tuple{String,String},Float64}()
    for (idx, sku_id) in problem.lane_sku_keys
        units = value(problem.transfer[(idx, sku_id)])
        units + 1e-6 < metadata.config.min_transfer_units && continue
        state = _solver_reduction_state(problem, idx, sku_id, incoming_reduction_used)
        sku = problem.sku_by_id[sku_id]
        net = _solver_value_metrics(problem, state, sku)
        explanation = _solver_explanation(problem, state, net, scenarios, metadata.status, metadata.decision.gap)
        push!(recs, _recommendation_tuple(snapshot, problem, state, net, explanation, sku_id, scenarios))
    end
    return recs
end

function solve_allocation_model(snapshot, scenarios; config::AllocationSolverConfig = AllocationSolverConfig())::NamedTuple
    config.timeout_seconds <= 0 && return _failed_solver_result("TIME_LIMIT", "solver timeout reached before optimization started", snapshot)
    problem = _build_solver_problem(snapshot, scenarios, config)
    if _region_blocked_with_demand(problem)
        return _failed_solver_result("INFEASIBLE", "region constraint blocks all feasible transfer lanes", snapshot)
    end
    _add_solver_constraints_and_objective!(problem)
    optimize!(problem.model)
    metadata = merge(_solver_decision(problem.model, config), (config = config,))
    if !metadata.decision.accepted
        return _failed_solver_result(metadata.status, "solver did not produce an acceptable solution ($(metadata.decision.reason))", snapshot)
    end
    recs = _allocation_recommendations(snapshot, problem, scenarios, metadata)
    isempty(recs) && return _empty_model_result(metadata.status, metadata.decision.gap, snapshot)
    return (
        status = "optimal",
        solver_status = metadata.status,
        optimality_gap = metadata.decision.gap,
        recommendations = recs,
        diagnostics = Dict{String,Any}("solver_status" => metadata.status, "optimality_gap" => metadata.decision.gap, "constraint_report" => _constraint_report(snapshot)),
    )
end

function _recommendation_row(ctx::TenantContext, run, rec)::Dict{Symbol,Any}
    now = Dates.now()
    return Dict{Symbol,Any}(
        :id => uuid4(), :tenant_id => ctx.tenant_id, :simulation_run_id => run[:id],
        :from_warehouse_id => UUID(rec.from_warehouse_id), :to_warehouse_id => UUID(rec.to_warehouse_id), :sku_id => UUID(rec.sku_id),
        :transfer_units => rec.transfer_units, :expected_stockout_reduction_units => rec.expected_stockout_reduction_units,
        :expected_margin_gain_cents => rec.expected_margin_gain_cents, :transfer_cost_cents => rec.transfer_cost_cents,
        :net_value_cents => rec.net_value_cents, :confidence_score => rec.confidence_score,
        :explanation => rec.explanation, :status => rec.status, :created_at => now, :updated_at => now,
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
    rows = Dict{Symbol,Any}[]
    for rec in result.recommendations
        row = _recommendation_row(ctx, run, rec)
        persist_allocation_recommendation_create!(store, row)
        push!(rows, row)
    end
    return [_recommendation_response(row) for row in rows]
end
