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
        return complete_simulation_run!(store, claimed)
    catch err
        return fail_simulation_run!(store, claimed, sprint(showerror, err))
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

function persist_simulation_run_create!(store::MemoryTenantAdminStore, row)
    store.simulation_runs[row[:id]] = row
    if row[:idempotency_key] !== nothing
        store.simulation_idempotency[(row[:tenant_id], row[:idempotency_key])] = row[:id]
    end
    return row
end

function fetch_simulation_run_by_idempotency_key(store::MemoryTenantAdminStore, tenant_id::UUID, key::String)
    id = get(store.simulation_idempotency, (tenant_id, key), nothing)
    id === nothing && return nothing
    return get(store.simulation_runs, id, nothing)
end

function fetch_simulation_run(store::MemoryTenantAdminStore, tenant_id::UUID, run_id::UUID)
    row = get(store.simulation_runs, run_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function fetch_simulation_runs(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.simulation_runs) if row[:tenant_id] == tenant_id]
    haskey(page.filters, "status") && (rows = [row for row in rows if row[:status] == _validate_run_status(page.filters["status"])])
    haskey(page.filters, "policy_id") && (rows = [row for row in rows if row[:policy_id] == _uuid_value(page.filters["policy_id"])])
    return first(sort(rows; by = row -> row[:created_at]), min(page.limit, length(rows)))
end

function persist_simulation_run_update!(store::MemoryTenantAdminStore, row)
    store.simulation_runs[row[:id]] = row
    return row
end

function persist_running_simulation_terminal_update!(store::MemoryTenantAdminStore, row)
    current = fetch_simulation_run(store, row[:tenant_id], row[:id])
    current === nothing && return row
    current[:status] == "running" || return current
    for key in (:status, :started_at, :completed_at, :error_message, :scenario_count, :updated_at)
        current[key] = row[key]
    end
    store.simulation_runs[current[:id]] = current
    return current
end

function fetch_next_queued_simulation_run(store::MemoryTenantAdminStore, tenant_id::UUID)
    rows = [row for row in values(store.simulation_runs) if row[:tenant_id] == tenant_id && row[:status] == "queued"]
    isempty(rows) && return nothing
    return first(sort(rows; by = row -> row[:created_at]))
end

function fetch_stale_simulation_runs(store::MemoryTenantAdminStore, tenant_id::UUID, cutoff::DateTime)
    return [row for row in values(store.simulation_runs) if row[:tenant_id] == tenant_id && row[:status] == "running" && row[:started_at] !== nothing && row[:started_at] <= cutoff]
end

function _sql_snapshot_value(value)
    _is_nullish(value) && return Dict{String,Any}()
    return JSON3.read(String(value))
end

function _sql_run_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :policy_id => UUID(String(row[3])),
        :name => row[4], :status => row[5], :input_snapshot => _sql_snapshot_value(row[6]),
        :scenario_count => Int(row[7]), :started_at => row[8], :completed_at => row[9],
        :error_message => _is_nullish(row[10]) ? nothing : String(row[10]),
        :created_by_user_id => _is_nullish(row[11]) ? nothing : UUID(String(row[11])),
        :idempotency_key => _is_nullish(row[12]) ? nothing : String(row[12]),
        :created_at => row[13], :updated_at => row[14],
    )
end

function persist_simulation_run_create!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO simulation_runs (id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6::jsonb, \$7, \$8, \$9, \$10, \$11, \$12)
    """, [string(row[:id]), string(row[:tenant_id]), string(row[:policy_id]), row[:name], row[:status], JSON3.write(row[:input_snapshot]), row[:scenario_count], _sql_null(row[:started_at]), _sql_null(row[:completed_at]), _sql_null(row[:error_message]), _sql_null(row[:created_by_user_id]), _sql_null(row[:idempotency_key])])
    return row
end

function fetch_simulation_run_by_idempotency_key(store::SqlTenantAdminStore, tenant_id::UUID, key::String)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key, created_at, updated_at
        FROM simulation_runs
        WHERE tenant_id = \$1 AND idempotency_key = \$2
        LIMIT 1
    """, [string(tenant_id), key])
    isempty(result) && return nothing
    return _sql_run_row(first(result))
end

function fetch_simulation_run(store::SqlTenantAdminStore, tenant_id::UUID, run_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key, created_at, updated_at
        FROM simulation_runs
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(run_id)])
    isempty(result) && return nothing
    return _sql_run_row(first(result))
end

function fetch_simulation_runs(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    status_filter = haskey(page.filters, "status") ? _validate_run_status(page.filters["status"]) : nothing
    policy_filter = haskey(page.filters, "policy_id") ? string(_uuid_value(page.filters["policy_id"])) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key, created_at, updated_at
        FROM simulation_runs
        WHERE tenant_id = \$1
          AND status = COALESCE(\$2::text, status)
          AND policy_id = COALESCE(\$3::uuid, policy_id)
        ORDER BY created_at
        LIMIT \$4
    """, [string(tenant_id), _sql_null(status_filter), _sql_null(policy_filter), page.limit])
    return [_sql_run_row(row) for row in result]
end

function persist_simulation_run_update!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        UPDATE simulation_runs
        SET status = \$3, started_at = \$4, completed_at = \$5, error_message = \$6, scenario_count = \$7, updated_at = now()
        WHERE tenant_id = \$1 AND id = \$2
    """, [string(row[:tenant_id]), string(row[:id]), row[:status], _sql_null(row[:started_at]), _sql_null(row[:completed_at]), _sql_null(row[:error_message]), row[:scenario_count]])
    return row
end

function persist_running_simulation_terminal_update!(store::SqlTenantAdminStore, row)
    result = LibPQ.execute(store.connection, """
        UPDATE simulation_runs
        SET status = \$3, started_at = \$4, completed_at = \$5, error_message = \$6, scenario_count = \$7, updated_at = now()
        WHERE tenant_id = \$1 AND id = \$2 AND status = 'running'
        RETURNING id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key, created_at, updated_at
    """, [string(row[:tenant_id]), string(row[:id]), row[:status], _sql_null(row[:started_at]), _sql_null(row[:completed_at]), _sql_null(row[:error_message]), row[:scenario_count]])
    !isempty(result) && return _sql_run_row(first(result))
    current = fetch_simulation_run(store, row[:tenant_id], row[:id])
    return current === nothing ? row : current
end

function fetch_next_queued_simulation_run(store::SqlTenantAdminStore, tenant_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key, created_at, updated_at
        FROM simulation_runs
        WHERE tenant_id = \$1 AND status = 'queued'
        ORDER BY created_at
        LIMIT 1
    """, [string(tenant_id)])
    isempty(result) && return nothing
    return _sql_run_row(first(result))
end

function fetch_stale_simulation_runs(store::SqlTenantAdminStore, tenant_id::UUID, cutoff::DateTime)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, policy_id, name, status, input_snapshot, scenario_count, started_at, completed_at, error_message, created_by_user_id, idempotency_key, created_at, updated_at
        FROM simulation_runs
        WHERE tenant_id = \$1 AND status = 'running' AND started_at <= \$2
        ORDER BY started_at
    """, [string(tenant_id), cutoff])
    return [_sql_run_row(row) for row in result]
end

function _simulation_job_contexts(store::SqlTenantAdminStore, status::AbstractString)::Vector{TenantContext}
    result = LibPQ.execute(store.connection, """
        SELECT DISTINCT tenant_id
        FROM simulation_runs
        WHERE status = \$1
        ORDER BY tenant_id
    """, [String(status)])
    return [TenantContext(UUID(String(row[1])); role = "admin", auth_method = :job) for row in result]
end

function claim_next_simulation_run_for_system!(
    store::SqlTenantAdminStore;
    worker_id::AbstractString = "simulation-worker",
    now::DateTime = Dates.now(),
)
    return with_advisory_lock!(store, advisory_lock_key("system", "simulation_worker")) do
        for ctx in _simulation_job_contexts(store, "queued")
            row = claim_next_simulation_run!(store, ctx; worker_id = worker_id, now = now)
            row !== nothing && return row
        end
        return nothing
    end
end

function simulation_worker!(
    store::SqlTenantAdminStore,
    config::AppConfig;
    worker_id::AbstractString = "simulation-worker",
    seed::Integer = 1,
)::Union{Nothing,NamedTuple}
    claimed = claim_next_simulation_run_for_system!(store; worker_id = worker_id)
    claimed === nothing && return nothing
    ctx = TenantContext(claimed[:tenant_id]; role = "admin", auth_method = :job)
    try
        generate_demand_scenarios!(store, ctx, claimed[:id]; seed = seed)
        return complete_simulation_run!(store, claimed)
    catch err
        return fail_simulation_run!(store, claimed, sprint(showerror, err))
    end
end

function reap_stale_simulation_runs!(
    store::SqlTenantAdminStore,
    config::AppConfig;
    now::DateTime = Dates.now(),
)::Int
    total = 0
    for ctx in _simulation_job_contexts(store, "running")
        total += reap_stale_simulation_runs!(store, ctx; stale_after_minutes = config.simulation.run_stale_after_minutes, now = now)
    end
    return total
end
