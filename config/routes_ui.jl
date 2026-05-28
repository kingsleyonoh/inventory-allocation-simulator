function register_ui_routes!(services::AppServices)::Nothing
    register_session_ui_routes!(services)
    register_catalog_ui_routes!(services)
    register_policy_settings_ui_routes!(services)
    register_simulation_review_ui_routes!(services)
    return nothing
end

function register_session_ui_routes!(services::AppServices)::Nothing
    route("/"; method = GET) do
        _redirect_response("/dashboard")
    end
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
    return nothing
end

function register_catalog_ui_routes!(services::AppServices)::Nothing
    route("/imports"; method = GET) do
        handle_imports_page(services)
    end
    route("/imports"; method = POST) do
        handle_create_import_form(services)
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
    return nothing
end

function register_policy_settings_ui_routes!(services::AppServices)::Nothing
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
    return nothing
end

function register_simulation_review_ui_routes!(services::AppServices)::Nothing
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
    route("/settings/integrations"; method = GET) do
        handle_integrations_page(services)
    end
    return nothing
end
