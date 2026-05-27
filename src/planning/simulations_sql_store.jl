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

function _allocation_solver_config(config::AppConfig)::AllocationSolverConfig
    return AllocationSolverConfig(
        timeout_seconds = config.simulation.solver_timeout_seconds,
        max_gap = config.simulation.max_solver_gap,
        min_transfer_units = config.simulation.min_transfer_units,
    )
end

function simulation_worker!(
    store::SqlTenantAdminStore,
    config::AppConfig;
    worker_id::AbstractString = "simulation-worker",
    seed::Integer = 1,
    solver_config::AllocationSolverConfig = _allocation_solver_config(config),
)::Union{Nothing,NamedTuple}
    claimed = claim_next_simulation_run_for_system!(store; worker_id = worker_id)
    claimed === nothing && return nothing
    ctx = TenantContext(claimed[:tenant_id]; role = "admin", auth_method = :job)
    try
        generate_demand_scenarios!(store, ctx, claimed[:id]; seed = seed)
        generate_allocation_recommendations!(store, ctx, claimed[:id]; config = solver_config)
        return complete_simulation_run!(store, claimed)
    catch err
        return fail_simulation_run!(store, claimed, _simulation_failure_message(err))
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
