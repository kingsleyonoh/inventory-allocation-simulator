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
    lines = _prometheus_header_lines(services, timestamp)
    append!(lines, _prometheus_counter_lines(observed))
    append!(lines, _histogram_lines("inventory_solver_duration_seconds", observed.solver_duration_seconds, [30.0, 60.0, 120.0, 300.0]))
    push!(lines, "")
    return join(lines, "\n")
end

function _prometheus_header_lines(services::AppServices, timestamp::DateTime)::Vector{String}
    env = replace(services.config.app.env, '"' => "")
    generated_at = Dates.datetime2unix(timestamp)
    return [
        "# HELP inventory_allocation_app_up Application process health flag.",
        "# TYPE inventory_allocation_app_up gauge",
        "inventory_allocation_app_up 1",
        "# HELP inventory_allocation_build_info Build/runtime metadata label gauge.",
        "# TYPE inventory_allocation_build_info gauge",
        "inventory_allocation_build_info{env=\"$env\"} 1",
        "# HELP inventory_allocation_metrics_generated_at_seconds Unix timestamp when metrics were generated.",
        "# TYPE inventory_allocation_metrics_generated_at_seconds gauge",
        "inventory_allocation_metrics_generated_at_seconds $generated_at",
    ]
end

function _prometheus_counter_lines(observed::OperationalMetrics)::Vector{String}
    return [
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
end
