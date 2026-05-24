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
        RouteDefinition(:POST, "/api/tenants/register", "tenant_register"),
        RouteDefinition(:GET, "/tenants/me", "tenant_me"),
        RouteDefinition(:GET, "/api/settings/tenant", "tenant_settings_read"),
        RouteDefinition(:PATCH, "/api/settings/tenant", "tenant_settings_update"),
        RouteDefinition(:POST, "/api/settings/api-key/rotate", "api_key_rotate"),
        RouteDefinition(:GET, "/api/users", "users_list"),
        RouteDefinition(:POST, "/api/users", "users_create"),
        RouteDefinition(:PATCH, "/api/users/:id", "users_update"),
        RouteDefinition(:GET, "/api/warehouses", "warehouses_list"),
        RouteDefinition(:POST, "/api/warehouses", "warehouses_create"),
        RouteDefinition(:GET, "/api/warehouses/:id", "warehouses_get"),
        RouteDefinition(:PATCH, "/api/warehouses/:id", "warehouses_update"),
        RouteDefinition(:DELETE, "/api/warehouses/:id", "warehouses_delete"),
        RouteDefinition(:GET, "/api/skus", "skus_list"),
        RouteDefinition(:POST, "/api/skus", "skus_create"),
        RouteDefinition(:GET, "/api/skus/:id", "skus_get"),
        RouteDefinition(:PATCH, "/api/skus/:id", "skus_update"),
        RouteDefinition(:DELETE, "/api/skus/:id", "skus_delete"),
        RouteDefinition(:GET, "/api/inventory", "inventory_list"),
        RouteDefinition(:PUT, "/api/inventory/:id", "inventory_update"),
        RouteDefinition(:GET, "/api/demand-history", "demand_history_list"),
        RouteDefinition(:GET, "/api/lanes", "lanes_list"),
        RouteDefinition(:POST, "/api/lanes", "lanes_create"),
        RouteDefinition(:GET, "/api/policies", "policies_list"),
        RouteDefinition(:POST, "/api/policies", "policies_create"),
        RouteDefinition(:POST, "/api/imports", "imports_create"),
        RouteDefinition(:GET, "/api/imports/:id", "imports_result"),
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

    if services !== nothing
        route("/api/tenants/register"; method = POST) do
            handle_register_tenant(services)
        end
        route("/tenants/me"; method = GET) do
            handle_tenant_me(services)
        end
        route("/api/settings/tenant"; method = GET) do
            handle_get_tenant_settings(services)
        end
        route("/api/settings/tenant"; method = PATCH) do
            handle_update_tenant_settings(services)
        end
        route("/api/users"; method = GET) do
            handle_list_users(services)
        end
        route("/api/users"; method = POST) do
            handle_create_user(services)
        end
        route("/api/users/:id"; method = PATCH) do
            handle_update_user(services)
        end
        route("/api/settings/api-key/rotate"; method = POST) do
            handle_rotate_api_key(services)
        end
        route("/api/warehouses"; method = GET) do
            handle_list_warehouses(services)
        end
        route("/api/warehouses"; method = POST) do
            handle_create_warehouse(services)
        end
        route("/api/warehouses/:id"; method = GET) do
            handle_get_warehouse(services)
        end
        route("/api/warehouses/:id"; method = PATCH) do
            handle_update_warehouse(services)
        end
        route("/api/warehouses/:id"; method = DELETE) do
            handle_delete_warehouse(services)
        end
        route("/api/skus"; method = GET) do
            handle_list_skus(services)
        end
        route("/api/skus"; method = POST) do
            handle_create_sku(services)
        end
        route("/api/skus/:id"; method = GET) do
            handle_get_sku(services)
        end
        route("/api/skus/:id"; method = PATCH) do
            handle_update_sku(services)
        end
        route("/api/skus/:id"; method = DELETE) do
            handle_delete_sku(services)
        end
        route("/api/inventory"; method = GET) do
            handle_list_inventory(services)
        end
        route("/api/inventory/:id"; method = PUT) do
            handle_update_inventory(services)
        end
        route("/api/demand-history"; method = GET) do
            handle_list_demand_history(services)
        end
        route("/api/lanes"; method = GET) do
            handle_list_lanes(services)
        end
        route("/api/lanes"; method = POST) do
            handle_create_lane(services)
        end
        route("/api/policies"; method = GET) do
            handle_list_policies(services)
        end
        route("/api/policies"; method = POST) do
            handle_create_policy(services)
        end
        route("/api/imports"; method = POST) do
            handle_create_import(services)
        end
        route("/api/imports/:id"; method = GET) do
            handle_get_import_result(services)
        end
    end

    return route_definitions()
end
