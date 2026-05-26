struct OperationalMetrics
    simulation_runs_total::Int
    simulation_failures_total::Int
    import_jobs_total::Int
    import_failures_total::Int
    outbox_dead_letters_total::Int
    database_up::Int
    solver_duration_seconds::Vector{Float64}
end

OperationalMetrics(; simulation_runs_total::Integer = 0, simulation_failures_total::Integer = 0, import_jobs_total::Integer = 0, import_failures_total::Integer = 0, outbox_dead_letters_total::Integer = 0, database_up::Integer = 1, solver_duration_seconds::AbstractVector = Float64[]) = OperationalMetrics(
    Int(simulation_runs_total),
    Int(simulation_failures_total),
    Int(import_jobs_total),
    Int(import_failures_total),
    Int(outbox_dead_letters_total),
    Int(database_up),
    Float64.(solver_duration_seconds),
)

function _seconds_between(started_at, completed_at)::Union{Nothing,Float64}
    (started_at === nothing || completed_at === nothing) && return nothing
    completed_at < started_at && return nothing
    return Dates.value(completed_at - started_at) / 1000.0
end

function _solver_durations_from_runs(rows)::Vector{Float64}
    durations = Float64[]
    for row in rows
        status = String(get(row, :status, ""))
        status in ("completed", "failed") || continue
        seconds = _seconds_between(get(row, :started_at, nothing), get(row, :completed_at, nothing))
        seconds === nothing || push!(durations, seconds)
    end
    return durations
end

function collect_operational_metrics(store::MemoryTenantAdminStore)::OperationalMetrics
    simulation_rows = collect(values(store.simulation_runs))
    import_rows = collect(values(store.import_jobs))
    outbox_rows = collect(values(store.ecosystem_outbox))
    return OperationalMetrics(
        simulation_runs_total = count(row -> get(row, :status, "") in ("queued", "running", "completed", "failed", "cancelled"), simulation_rows),
        simulation_failures_total = count(row -> get(row, :status, "") == "failed", simulation_rows),
        import_jobs_total = length(import_rows),
        import_failures_total = count(row -> get(row, :status, "") == "failed", import_rows),
        outbox_dead_letters_total = count(row -> get(row, :status, "") == "dead_letter", outbox_rows),
        database_up = 1,
        solver_duration_seconds = _solver_durations_from_runs(simulation_rows),
    )
end

function _sql_count_scalar(store::SqlTenantAdminStore, sql::AbstractString)::Int
    result = LibPQ.execute(store.connection, sql)
    isempty(result) && return 0
    return Int(first(first(result)))
end

function _sql_solver_durations(store::SqlTenantAdminStore)::Vector{Float64}
    result = LibPQ.execute(store.connection, """
        SELECT EXTRACT(EPOCH FROM (completed_at - started_at))::double precision
        FROM simulation_runs
        WHERE status IN ('completed', 'failed')
          AND started_at IS NOT NULL
          AND completed_at IS NOT NULL
          AND completed_at >= started_at
        ORDER BY completed_at
    """)
    return [Float64(row[1]) for row in result]
end

function collect_operational_metrics(store::SqlTenantAdminStore)::OperationalMetrics
    return OperationalMetrics(
        simulation_runs_total = _sql_count_scalar(store, "SELECT count(*) FROM simulation_runs WHERE status IN ('queued', 'running', 'completed', 'failed', 'cancelled')"),
        simulation_failures_total = _sql_count_scalar(store, "SELECT count(*) FROM simulation_runs WHERE status = 'failed'"),
        import_jobs_total = _sql_count_scalar(store, "SELECT count(*) FROM import_jobs"),
        import_failures_total = _sql_count_scalar(store, "SELECT count(*) FROM import_jobs WHERE status = 'failed'"),
        outbox_dead_letters_total = _sql_count_scalar(store, "SELECT count(*) FROM ecosystem_outbox WHERE status = 'dead_letter'"),
        database_up = 1,
        solver_duration_seconds = _sql_solver_durations(store),
    )
end

function collect_operational_metrics(services::AppServices)::OperationalMetrics
    try
        store = SqlTenantAdminStore(connect!(services.db))
        return collect_operational_metrics(store)
    catch err
        @warn "Prometheus operational metrics collection failed" exception = (err, catch_backtrace())
        return OperationalMetrics(database_up = 0)
    end
end
