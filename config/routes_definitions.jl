struct RouteDefinition
    method::Symbol
    path::String
    name::String
end

_health_route_definitions() = [
    RouteDefinition(:GET, "/health", "health"),
    RouteDefinition(:GET, "/health/db", "health_db"),
    RouteDefinition(:GET, "/health/ready", "health_ready"),
    RouteDefinition(:GET, "/metrics", "metrics"),
]

_ui_route_definitions() = [
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
]

_ui_phase3_route_definitions() = [
    RouteDefinition(:GET, "/simulations", "simulations_page"),
    RouteDefinition(:POST, "/simulations", "simulations_create_form"),
    RouteDefinition(:GET, "/simulations/:id", "simulations_detail_page"),
    RouteDefinition(:POST, "/simulations/:id/cancel", "simulations_cancel_form"),
    RouteDefinition(:GET, "/recommendations/:id", "recommendation_detail_page"),
    RouteDefinition(:GET, "/notifications", "notifications_page"),
    RouteDefinition(:POST, "/notifications/:id/read", "notifications_read_form"),
    RouteDefinition(:GET, "/integrations", "integrations_page"),
]

_tenant_api_route_definitions() = [
    RouteDefinition(:POST, "/api/tenants/register", "tenant_register"),
    RouteDefinition(:GET, "/tenants/me", "tenant_me"),
    RouteDefinition(:GET, "/api/settings/tenant", "tenant_settings_read"),
    RouteDefinition(:PATCH, "/api/settings/tenant", "tenant_settings_update"),
    RouteDefinition(:POST, "/api/settings/api-key/rotate", "api_key_rotate"),
    RouteDefinition(:GET, "/api/users", "users_list"),
    RouteDefinition(:POST, "/api/users", "users_create"),
    RouteDefinition(:PATCH, "/api/users/:id", "users_update"),
]

_catalog_api_route_definitions() = [
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
]

_simulation_import_api_route_definitions() = [
    RouteDefinition(:POST, "/api/simulations", "simulations_create"),
    RouteDefinition(:GET, "/api/simulations", "simulations_list"),
    RouteDefinition(:GET, "/api/simulations/:id", "simulations_get"),
    RouteDefinition(:POST, "/api/simulations/:id/cancel", "simulations_cancel"),
    RouteDefinition(:POST, "/api/imports", "imports_create"),
    RouteDefinition(:GET, "/api/imports/:id", "imports_result"),
]

_recommendation_api_route_definitions() = [
    RouteDefinition(:GET, "/api/recommendations", "recommendations_list"),
    RouteDefinition(:GET, "/api/recommendations/:id", "recommendations_get"),
    RouteDefinition(:POST, "/api/recommendations/:id/approve", "recommendations_approve"),
    RouteDefinition(:POST, "/api/recommendations/:id/reject", "recommendations_reject"),
    RouteDefinition(:POST, "/api/recommendations/:id/expire", "recommendations_expire"),
    RouteDefinition(:POST, "/api/recommendations/:id/export", "recommendations_export"),
    RouteDefinition(:GET, "/api/recommendations/:id/export.csv", "recommendations_export_csv"),
    RouteDefinition(:GET, "/api/notifications", "notifications_list"),
    RouteDefinition(:PATCH, "/api/notifications/:id/read", "notifications_read"),
]

function route_definitions()::Vector{RouteDefinition}
    return vcat(
        _health_route_definitions(),
        _ui_route_definitions(),
        _ui_phase3_route_definitions(),
        _recommendation_api_route_definitions(),
        _tenant_api_route_definitions(),
        _catalog_api_route_definitions(),
        _simulation_import_api_route_definitions(),
    )
end
