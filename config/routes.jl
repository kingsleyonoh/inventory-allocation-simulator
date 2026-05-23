using Genie.Router
using Genie.Renderer: respond
using JSON3

struct RouteDefinition
    method::Symbol
    path::String
    name::String
end

function route_definitions()::Vector{RouteDefinition}
    return [
        RouteDefinition(:GET, "/health", "health"),
        RouteDefinition(:GET, "/health/db", "health_db"),
    ]
end

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

function register_routes!(services::Union{Nothing,AppServices} = nothing)
    route("/health") do
        respond(JSON3.write(health_response()), :json, 200)
    end

    route("/health/db") do
        response = if services === nothing
            (status = "unavailable", service = "postgresql", error = "services_not_configured")
        else
            db_health_response(services)
        end
        respond(JSON3.write(response), :json, response.status == "ok" ? 200 : 503)
    end

    return route_definitions()
end
