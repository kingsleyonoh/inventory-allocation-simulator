using Dates
using UUIDs

const OBSERVABILITY_KEY_EVENTS = Set([
    "tenant_registered",
    "import_completed",
    "simulation_started",
    "simulation_completed",
    "recommendation_approved",
    "recommendation_exported",
])

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

function _observability_require_text(value::AbstractString, field::AbstractString)::String
    cleaned = strip(String(value))
    isempty(cleaned) && throw(ApiError("VALIDATION_ERROR", "$field is required"; status = 400))
    return cleaned
end

function normalized_observability_event_type(event_type::AbstractString)::String
    lowered = lowercase(strip(String(event_type)))
    return replace(lowered, r"[\.\s]+" => "_")
end

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

function _histogram_lines(name::AbstractString, values::Vector{Float64}, buckets::Vector{Float64})::Vector{String}
    lines = String[]
    for bucket in buckets
        label = isinteger(bucket) ? string(Int(bucket)) : string(bucket)
        push!(lines, "$(name)_bucket{le=\"$label\"} $(count(value -> value <= bucket, values))")
    end
    push!(lines, "$(name)_bucket{le=\"+Inf\"} $(length(values))")
    push!(lines, "$(name)_count $(length(values))")
    push!(lines, "$(name)_sum $(sum(values))")
    return lines
end

function metrics_authorized(services::AppServices, headers::AbstractDict)::Bool
    token = services.config.observability.metrics_token
    isempty(strip(token)) && return false
    for (key, value) in headers
        name = lowercase(String(key))
        candidate = strip(String(value))
        if name == "x-metrics-token" && candidate == token
            return true
        elseif name == "authorization" && candidate == "Bearer $token"
            return true
        end
    end
    return false
end

function prometheus_metrics_text(services::AppServices; timestamp::DateTime = Dates.now(), metrics::Union{Nothing,OperationalMetrics} = nothing)::String
    observed = metrics === nothing ? collect_operational_metrics(services) : metrics
    env = replace(services.config.app.env, '"' => "")
    generated_at = Dates.datetime2unix(timestamp)
    lines = [
        "# HELP inventory_allocation_app_up Application process health flag.",
        "# TYPE inventory_allocation_app_up gauge",
        "inventory_allocation_app_up 1",
        "# HELP inventory_allocation_build_info Build/runtime metadata label gauge.",
        "# TYPE inventory_allocation_build_info gauge",
        "inventory_allocation_build_info{env=\"$env\"} 1",
        "# HELP inventory_allocation_metrics_generated_at_seconds Unix timestamp when metrics were generated.",
        "# TYPE inventory_allocation_metrics_generated_at_seconds gauge",
        "inventory_allocation_metrics_generated_at_seconds $generated_at",
        "# HELP inventory_simulation_runs_total Simulation runs observed by workers.",
        "# TYPE inventory_simulation_runs_total counter",
        "inventory_simulation_runs_total $(observed.simulation_runs_total)",
        "# HELP inventory_simulation_failures_total Simulation failures observed by workers.",
        "# TYPE inventory_simulation_failures_total counter",
        "inventory_simulation_failures_total $(observed.simulation_failures_total)",
        "# HELP inventory_import_jobs_total Import jobs observed by workers.",
        "# TYPE inventory_import_jobs_total counter",
        "inventory_import_jobs_total $(observed.import_jobs_total)",
        "# HELP inventory_import_failures_total Import failures observed by workers.",
        "# TYPE inventory_import_failures_total counter",
        "inventory_import_failures_total $(observed.import_failures_total)",
        "# HELP inventory_outbox_dead_letters_total Ecosystem outbox dead-letter events.",
        "# TYPE inventory_outbox_dead_letters_total counter",
        "inventory_outbox_dead_letters_total $(observed.outbox_dead_letters_total)",
        "# HELP inventory_database_up PostgreSQL health status from metrics collection.",
        "# TYPE inventory_database_up gauge",
        "inventory_database_up $(observed.database_up)",
        "# HELP inventory_solver_duration_seconds Allocation solver runtime histogram.",
        "# TYPE inventory_solver_duration_seconds histogram",
    ]
    append!(lines, _histogram_lines("inventory_solver_duration_seconds", observed.solver_duration_seconds, [30.0, 60.0, 120.0, 300.0]))
    push!(lines, "")
    return join(lines, "\n")
end

function ready_health_response(
    services::AppServices;
    migration_dir::AbstractString = joinpath(project_root(), "migrations"),
    migration_store::Union{Nothing,AbstractMigrationStore} = nothing,
)
    database = db_health_response(services; migration_dir = migration_dir, migration_store = migration_store)
    ready = database.status == "ok"
    return (status = ready ? "ready" : "not_ready", service = "inventory-allocation-simulator", database = database)
end

function build_local_error_event(
    event_type::AbstractString;
    tenant_id::Union{Nothing,UUID} = nothing,
    source::AbstractString,
    message::AbstractString,
    request_id::Union{Nothing,AbstractString} = nothing,
    details::AbstractDict = Dict{String,Any}(),
    occurred_at::DateTime = Dates.now(),
)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => uuid4(),
        :tenant_id => tenant_id,
        :event_type => _observability_require_text(event_type, "event_type"),
        :source => _observability_require_text(source, "source"),
        :message => _observability_require_text(message, "message"),
        :request_id => request_id === nothing ? nothing : String(request_id),
        :details => Dict{String,Any}(String(key) => value for (key, value) in details),
        :occurred_at => occurred_at,
    )
end

function build_local_analytics_event(
    event_type::AbstractString;
    tenant_id::Union{Nothing,UUID} = nothing,
    user_id::Union{Nothing,UUID} = nothing,
    properties::AbstractDict = Dict{String,Any}(),
    occurred_at::DateTime = Dates.now(),
)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => uuid4(),
        :tenant_id => tenant_id,
        :user_id => user_id,
        :event_type => normalized_observability_event_type(_observability_require_text(event_type, "event_type")),
        :properties => Dict{String,Any}(String(key) => value for (key, value) in properties),
        :occurred_at => occurred_at,
    )
end

function record_local_error_event!(store::SqlTenantAdminStore, event::AbstractDict)::UUID
    id = get(event, :id, uuid4())
    tenant_id = get(event, :tenant_id, nothing)
    params = [
        string(id),
        tenant_id === nothing ? missing : string(tenant_id),
        String(get(event, :event_type, "")),
        String(get(event, :source, "")),
        String(get(event, :message, "")),
        get(event, :request_id, nothing) === nothing ? missing : String(event[:request_id]),
        JSON3.write(get(event, :details, Dict{String,Any}())),
    ]
    LibPQ.execute(store.connection, """
        INSERT INTO local_error_events (id, tenant_id, event_type, source, message, request_id, details)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7::jsonb)
    """, params)
    return id
end

function record_local_analytics_event!(store::SqlTenantAdminStore, event::AbstractDict)::UUID
    id = get(event, :id, uuid4())
    tenant_id = get(event, :tenant_id, nothing)
    user_id = get(event, :user_id, nothing)
    params = [
        string(id),
        tenant_id === nothing ? missing : string(tenant_id),
        user_id === nothing ? missing : string(user_id),
        String(get(event, :event_type, "")),
        JSON3.write(get(event, :properties, Dict{String,Any}())),
    ]
    LibPQ.execute(store.connection, """
        INSERT INTO local_analytics_events (id, tenant_id, user_id, event_type, properties)
        VALUES (\$1, \$2, \$3, \$4, \$5::jsonb)
    """, params)
    return id
end
