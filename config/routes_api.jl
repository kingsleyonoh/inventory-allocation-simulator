function register_api_routes!(services::AppServices)::Nothing
    register_tenant_api_routes!(services)
    register_catalog_api_routes!(services)
    register_simulation_import_api_routes!(services)
    register_recommendation_api_routes!(services)
    return nothing
end

function register_tenant_api_routes!(services::AppServices)::Nothing
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
    return nothing
end

function register_catalog_api_routes!(services::AppServices)::Nothing
    register_warehouse_sku_api_routes!(services)
    register_inventory_policy_api_routes!(services)
    return nothing
end

function register_warehouse_sku_api_routes!(services::AppServices)::Nothing
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
    return nothing
end

function register_inventory_policy_api_routes!(services::AppServices)::Nothing
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
    return nothing
end

function register_simulation_import_api_routes!(services::AppServices)::Nothing
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
    return nothing
end

function register_recommendation_api_routes!(services::AppServices)::Nothing
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
    return nothing
end
