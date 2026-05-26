health_response() = (status = "ok", service = "inventory-allocation-simulator")

function db_health_response(
    services::AppServices;
    migration_dir::AbstractString = joinpath(project_root(), "migrations"),
    migration_store::Union{Nothing,AbstractMigrationStore} = nothing,
)
    store = migration_store
    should_close = migration_store === nothing
    try
        store === nothing && (store = SqlMigrationStore(services.config.database.url))
        migrations = migration_health(store::AbstractMigrationStore, migration_dir)
        return (status = migrations.status == :current ? "ok" : "pending", service = "postgresql", migrations = migrations)
    catch err
        @warn "Database health check failed" exception = (err, catch_backtrace())
        return (status = "unavailable", service = "postgresql", error = "database_unavailable")
    finally
        if should_close && store isa SqlMigrationStore
            try
                close!(store)
            catch err
                @debug "Database health store close skipped" exception = (err, catch_backtrace())
            end
        end
    end
end

function register_health_routes!(services::Union{Nothing,AppServices})::Nothing
    route("/health") do
        respond(JSON3.write(health_response()), :json, 200)
    end

    route("/health/db") do
        response = services === nothing ? _services_not_configured_db_health() : db_health_response(services)
        respond(JSON3.write(response), :json, response.status == "ok" ? 200 : 503)
    end

    route("/health/ready") do
        response = services === nothing ? _services_not_configured_ready_health() : ready_health_response(services)
        respond(JSON3.write(response), :json, response.status == "ready" ? 200 : 503)
    end

    route("/metrics") do
        if services === nothing || !metrics_authorized(services, _request_headers_dict())
            return HTTP.Response(401, ["Content-Type" => "text/plain"], "metrics token required\n")
        end
        return HTTP.Response(200, ["Content-Type" => "text/plain; version=0.0.4"], prometheus_metrics_text(services))
    end
    return nothing
end

_services_not_configured_db_health() = (status = "unavailable", service = "postgresql", error = "services_not_configured")

_services_not_configured_ready_health() = (
    status = "not_ready",
    service = "inventory-allocation-simulator",
    database = _services_not_configured_db_health(),
)
