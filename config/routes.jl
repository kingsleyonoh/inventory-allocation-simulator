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
        RouteDefinition(:GET, "/login", "login_page"),
        RouteDefinition(:POST, "/login", "login_create"),
        RouteDefinition(:POST, "/logout", "logout"),
        RouteDefinition(:GET, "/dashboard", "dashboard"),
        RouteDefinition(:GET, "/imports", "imports_page"),
        RouteDefinition(:GET, "/warehouses", "warehouses_page"),
        RouteDefinition(:POST, "/warehouses", "warehouses_create_form"),
        RouteDefinition(:POST, "/warehouses/:id", "warehouses_update_form"),
        RouteDefinition(:GET, "/skus", "skus_page"),
        RouteDefinition(:POST, "/skus", "skus_create_form"),
        RouteDefinition(:POST, "/skus/:id", "skus_update_form"),
        RouteDefinition(:GET, "/lanes", "lanes_page"),
        RouteDefinition(:POST, "/lanes", "lanes_create_form"),
        RouteDefinition(:POST, "/lanes/:id", "lanes_update_form"),
        RouteDefinition(:GET, "/policies", "policies_page"),
        RouteDefinition(:POST, "/policies", "policies_create_form"),
        RouteDefinition(:POST, "/policies/:id", "policies_update_form"),
        RouteDefinition(:GET, "/settings", "settings_page"),
        RouteDefinition(:POST, "/settings", "settings_update_form"),
        RouteDefinition(:POST, "/settings/users", "settings_users_create_form"),
        RouteDefinition(:POST, "/settings/users/:id", "settings_users_update_form"),
        RouteDefinition(:POST, "/settings/api-key/rotate", "settings_api_key_rotate_form"),
        RouteDefinition(:GET, "/simulations", "simulations_page"),
        RouteDefinition(:POST, "/simulations", "simulations_create_form"),
        RouteDefinition(:GET, "/simulations/:id", "simulations_detail_page"),
        RouteDefinition(:POST, "/simulations/:id/cancel", "simulations_cancel_form"),
        RouteDefinition(:GET, "/recommendations/:id", "recommendation_detail_page"),
        RouteDefinition(:GET, "/notifications", "notifications_page"),
        RouteDefinition(:POST, "/notifications/:id/read", "notifications_read_form"),
        RouteDefinition(:GET, "/integrations", "integrations_page"),
        RouteDefinition(:GET, "/api/recommendations", "recommendations_list"),
        RouteDefinition(:GET, "/api/recommendations/:id", "recommendations_get"),
        RouteDefinition(:POST, "/api/recommendations/:id/approve", "recommendations_approve"),
        RouteDefinition(:POST, "/api/recommendations/:id/reject", "recommendations_reject"),
        RouteDefinition(:POST, "/api/recommendations/:id/expire", "recommendations_expire"),
        RouteDefinition(:POST, "/api/recommendations/:id/export", "recommendations_export"),
        RouteDefinition(:GET, "/api/recommendations/:id/export.csv", "recommendations_export_csv"),
        RouteDefinition(:GET, "/api/notifications", "notifications_list"),
        RouteDefinition(:PATCH, "/api/notifications/:id/read", "notifications_read"),
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
        RouteDefinition(:POST, "/api/simulations", "simulations_create"),
        RouteDefinition(:GET, "/api/simulations", "simulations_list"),
        RouteDefinition(:GET, "/api/simulations/:id", "simulations_get"),
        RouteDefinition(:POST, "/api/simulations/:id/cancel", "simulations_cancel"),
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
        route("/login"; method = GET) do
            handle_login_page(services)
        end
        route("/login"; method = POST) do
            handle_login(services)
        end
        route("/logout"; method = POST) do
            handle_logout(services)
        end
        route("/dashboard"; method = GET) do
            handle_dashboard(services)
        end
        route("/imports"; method = GET) do
            handle_imports_page(services)
        end
        route("/warehouses"; method = GET) do
            handle_warehouses_page(services)
        end
        route("/warehouses"; method = POST) do
            handle_create_warehouse_form(services)
        end
        route("/warehouses/:id"; method = POST) do
            handle_update_warehouse_form(services)
        end
        route("/skus"; method = GET) do
            handle_skus_page(services)
        end
        route("/skus"; method = POST) do
            handle_create_sku_form(services)
        end
        route("/skus/:id"; method = POST) do
            handle_update_sku_form(services)
        end
        route("/lanes"; method = GET) do
            handle_lanes_page(services)
        end
        route("/lanes"; method = POST) do
            handle_create_lane_form(services)
        end
        route("/lanes/:id"; method = POST) do
            handle_update_lane_form(services)
        end
        route("/policies"; method = GET) do
            handle_policies_page(services)
        end
        route("/policies"; method = POST) do
            handle_create_policy_form(services)
        end
        route("/policies/:id"; method = POST) do
            handle_update_policy_form(services)
        end
        route("/settings"; method = GET) do
            handle_settings_page(services)
        end
        route("/settings"; method = POST) do
            handle_update_settings_form(services)
        end
        route("/settings/users"; method = POST) do
            handle_create_user_form(services)
        end
        route("/settings/users/:id"; method = POST) do
            handle_update_user_form(services)
        end
        route("/settings/api-key/rotate"; method = POST) do
            handle_rotate_api_key_form(services)
        end
        route("/simulations"; method = GET) do
            handle_simulations_page(services)
        end
        route("/simulations"; method = POST) do
            handle_create_simulation_form(services)
        end
        route("/simulations/:id"; method = GET) do
            handle_simulation_detail_page(services)
        end
        route("/simulations/:id/cancel"; method = POST) do
            handle_cancel_simulation_form(services)
        end
        route("/recommendations/:id"; method = GET) do
            handle_recommendation_detail_page(services)
        end
        route("/notifications"; method = GET) do
            handle_notifications_page(services)
        end
        route("/notifications/:id/read"; method = POST) do
            handle_mark_notification_read_form(services)
        end
        route("/integrations"; method = GET) do
            handle_integrations_page(services)
        end
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
        route("/api/simulations"; method = POST) do
            handle_create_simulation(services)
        end
        route("/api/simulations"; method = GET) do
            handle_list_simulations(services)
        end
        route("/api/simulations/:id"; method = GET) do
            handle_get_simulation(services)
        end
        route("/api/simulations/:id/cancel"; method = POST) do
            handle_cancel_simulation(services)
        end
        route("/api/imports"; method = POST) do
            handle_create_import(services)
        end
        route("/api/imports/:id"; method = GET) do
            handle_get_import_result(services)
        end
        route("/api/recommendations"; method = GET) do
            handle_list_recommendations(services)
        end
        route("/api/recommendations/:id"; method = GET) do
            handle_get_recommendation(services)
        end
        route("/api/recommendations/:id/approve"; method = POST) do
            handle_approve_recommendation(services)
        end
        route("/api/recommendations/:id/reject"; method = POST) do
            handle_reject_recommendation(services)
        end
        route("/api/recommendations/:id/expire"; method = POST) do
            handle_expire_recommendation(services)
        end
        route("/api/recommendations/:id/export"; method = POST) do
            handle_export_recommendation(services)
        end
        route("/api/recommendations/:id/export.csv"; method = GET) do
            handle_export_recommendation_csv(services)
        end
        route("/api/notifications"; method = GET) do
            handle_list_notifications(services)
        end
        route("/api/notifications/:id/read"; method = PATCH) do
            handle_mark_notification_read(services)
        end
    end

    return route_definitions()
end
