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
