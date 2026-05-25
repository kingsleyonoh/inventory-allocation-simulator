const SIMULATION_STATUSES = Set(["queued", "running", "completed", "failed", "cancelled"])

function _simulation_count(payload)::Int
    count = _optional_int(payload, "scenario_count", 100)
    count > 0 || throw(ApiError("VALIDATION_ERROR", "scenario_count must be greater than zero"; status = 400))
    return count
end

function _simulation_response(row; scenarios = NamedTuple[])::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        policy_id = string(row[:policy_id]),
        name = String(row[:name]),
        status = String(row[:status]),
        input_snapshot = row[:input_snapshot],
        scenario_count = Int(row[:scenario_count]),
        started_at = get(row, :started_at, nothing),
        completed_at = get(row, :completed_at, nothing),
        error_message = get(row, :error_message, nothing),
        created_by_user_id = _is_nullish(get(row, :created_by_user_id, nothing)) ? nothing : string(row[:created_by_user_id]),
        scenarios = scenarios,
    )
end

function _run_page(params)::CursorPageRequest
    return parse_cursor_params(params; allowed_filters = Set(["status", "policy_id"]))
end

function _validate_run_status(status::AbstractString)::String
    status in SIMULATION_STATUSES || throw(ApiError("VALIDATION_ERROR", "simulation status is invalid"; status = 400))
    return String(status)
end

function create_simulation_run!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext,
    payload;
    idempotency_key::Union{Nothing,String} = nothing,
)::NamedTuple
    authorize!(ctx, "run_cancel", "simulation")
    if idempotency_key !== nothing
        existing = fetch_simulation_run_by_idempotency_key(store, ctx.tenant_id, idempotency_key)
        existing !== nothing && return _simulation_response(existing; scenarios = [_scenario_response(row) for row in fetch_demand_scenarios(store, ctx.tenant_id, existing[:id])])
    end
    policy_id = _uuid_value(_required_text(payload, "policy_id"))
    name = _required_text(payload, "name")
    snapshot = capture_simulation_input_snapshot(store, ctx, policy_id)
    now = Dates.now()
    row = Dict{Symbol,Any}(
        :id => uuid4(),
        :tenant_id => ctx.tenant_id,
        :policy_id => policy_id,
        :name => name,
        :status => "queued",
        :input_snapshot => snapshot,
        :scenario_count => _simulation_count(payload),
        :started_at => nothing,
        :completed_at => nothing,
        :error_message => nothing,
        :created_by_user_id => ctx.user_id,
        :idempotency_key => idempotency_key,
        :created_at => now,
        :updated_at => now,
    )
    persist_simulation_run_create!(store, row)
    return _simulation_response(row)
end

function list_simulation_runs(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, "read", "planning_data")
    page = _run_page(params)
    rows = fetch_simulation_runs(store, ctx.tenant_id, page)
    return _page_response(:simulation_runs, [_simulation_response(row) for row in rows], page)
end

function get_simulation_run(store::AbstractTenantAdminStore, ctx::TenantContext, run_id)::NamedTuple
    authorize!(ctx, "read", "planning_data")
    row = fetch_simulation_run(store, ctx.tenant_id, _uuid_value(run_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
    scenarios = [_scenario_response(item) for item in fetch_demand_scenarios(store, ctx.tenant_id, row[:id])]
    return _simulation_response(row; scenarios = scenarios)
end

function cancel_simulation_run!(store::AbstractTenantAdminStore, ctx::TenantContext, run_id)::NamedTuple
    authorize!(ctx, "run_cancel", "simulation")
    row = fetch_simulation_run(store, ctx.tenant_id, _uuid_value(run_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
    row[:status] in ("queued", "running") || throw(ApiError("CONFLICT", "Only queued or running simulations can be cancelled"; status = 409))
    row[:status] = "cancelled"
    row[:completed_at] = Dates.now()
    row[:updated_at] = Dates.now()
    persist_simulation_run_update!(store, row)
    return _simulation_response(row)
end

function claim_next_simulation_run!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext;
    worker_id::AbstractString = "simulation-worker",
    now::DateTime = Dates.now(),
)
    authorize!(ctx, "run_cancel", "simulation")
    return with_advisory_lock!(store, advisory_lock_key(ctx.tenant_id, "simulation_worker")) do
        row = fetch_next_queued_simulation_run(store, ctx.tenant_id)
        row === nothing && return nothing
        row[:status] = "running"
        row[:started_at] = now
        row[:updated_at] = now
        row[:worker_id] = String(worker_id)
        persist_simulation_run_update!(store, row)
        return row
    end
end

function _simulation_response_with_scenarios(store::AbstractTenantAdminStore, row)::NamedTuple
    scenarios = [_scenario_response(item) for item in fetch_demand_scenarios(store, row[:tenant_id], row[:id])]
    return _simulation_response(row; scenarios = scenarios)
end

function _terminal_simulation_run!(
    store::AbstractTenantAdminStore,
    row,
    status::AbstractString;
    error_message = nothing,
)::NamedTuple
    current = fetch_simulation_run(store, row[:tenant_id], row[:id])
    current === nothing && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
    current[:status] == "running" || return _simulation_response_with_scenarios(store, current)
    current[:status] = String(status)
    current[:error_message] = error_message
    current[:completed_at] = Dates.now()
    current[:updated_at] = Dates.now()
    updated = persist_running_simulation_terminal_update!(store, current)
    return _simulation_response_with_scenarios(store, updated)
end

function complete_simulation_run!(store::AbstractTenantAdminStore, row)::NamedTuple
    return _terminal_simulation_run!(store, row, "completed")
end

function fail_simulation_run!(store::AbstractTenantAdminStore, row, message::AbstractString)::NamedTuple
    return _terminal_simulation_run!(store, row, "failed"; error_message = String(message))
end

function _simulation_failure_message(err)::String
    message = sprint(showerror, err)
    if err isa ApiError && !isempty(err.details)
        return string(message, " details=", JSON3.write(err.details))
    end
    return message
end

function simulation_worker!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext;
    worker_id::AbstractString = "simulation-worker",
    seed::Integer = 1,
)::Union{Nothing,NamedTuple}
    claimed = claim_next_simulation_run!(store, ctx; worker_id = worker_id)
    claimed === nothing && return nothing
    if claimed[:status] == "cancelled"
        return _simulation_response(claimed)
    end
    try
        generate_demand_scenarios!(store, ctx, claimed[:id]; seed = seed)
        generate_allocation_recommendations!(store, ctx, claimed[:id])
        return complete_simulation_run!(store, claimed)
    catch err
        return fail_simulation_run!(store, claimed, _simulation_failure_message(err))
    end
end

function reap_stale_simulation_runs!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext;
    stale_after_minutes::Int = 30,
    now::DateTime = Dates.now(),
)::Int
    authorize!(ctx, "run_cancel", "simulation")
    rows = fetch_stale_simulation_runs(store, ctx.tenant_id, now - Minute(stale_after_minutes))
    for row in rows
        row[:status] = "failed"
        row[:error_message] = "Simulation run marked failed by stale_run_reaper after stale timeout"
        row[:completed_at] = now
        row[:updated_at] = now
        persist_simulation_run_update!(store, row)
    end
    return length(rows)
end
