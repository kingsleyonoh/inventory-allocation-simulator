module InventoryAllocationSimulator

using Genie

const DEFAULT_HOST = "0.0.0.0"
const DEFAULT_PORT = 8000

include("../config/app.jl")
include("db/connection.jl")
include("db/migrations.jl")
include("cache/request_cache.jl")
include("tenant/context.jl")
include("db/scoped_queries.jl")
include("web/errors.jl")
include("web/pagination.jl")
include("web/rate_limit.jl")
include("tenant/bootstrap.jl")
include("tenant/auth.jl")
include("tenant/authz.jl")
include("tenant/admin_api.jl")
include("planning/catalog.jl")
include("planning/snapshots.jl")
include("planning/forecasts.jl")
include("planning/scenarios.jl")
include("solver/model_builder.jl")
include("planning/simulations.jl")
include("planning/backtests.jl")
include("recommendations/decisions.jl")
include("notifications/local_notifications.jl")
include("imports/importer.jl")
include("jobs/locks.jl")
include("jobs/worker.jl")
include("recommendations/expiry_jobs.jl")
include("observability/logging.jl")
include("services.jl")
include("web/controllers/tenant_admin_controller.jl")
include("web/controllers/planning_catalog_controller.jl")
include("web/controllers/simulation_controller.jl")
include("web/controllers/recommendation_controller.jl")
include("web/controllers/notification_controller.jl")
include("web/controllers/ui_controller.jl")
include("web/controllers/ui_batch027_controller.jl")
include("imports/demo_seed.jl")
include("../config/routes.jl")

export AppConfig, AppServices, SetupResult
export load_config, load_env_file!, project_root, parse_port
export build_services, shutdown!, install_shutdown_hook!, start_runtime_jobs!, run_server!, main, register_routes!, route_definitions, health_response, db_health_response
export RequestCache, get_cached!, cache_keys
export TenantContext, require_tenant_context, tenant_cache_key, tenant_filter_records
export tenant_where_clause, tenant_scoped_select, assert_tenant_scoped_sql, inventory_positions_with_dimensions_sql
export ApiError, format_error_response, endpoint_error_response
export CursorPageRequest, parse_cursor_params, cursor_where_clause
export RateLimitPolicy, RateLimitDecision, MemoryRateLimiter, check_rate_limit!, default_rate_limit_policy
export first_run_setup!, generate_api_key, hash_api_key, AbstractSetupStore, count_tenants, insert_tenant!, insert_admin_user!
export AbstractAuthStore, AuthError, TenantAuthRecord, SessionAuthRecord, AuthRequest
export signed_session_cookie, verify_session_cookie, resolve_tenant_context, lookup_tenant_by_api_key_hash, lookup_session_record
export AuthzError, AuthzPolicy, AuthorizationRegistry, load_authz_registry, default_authz_registry, policy_key, authorize!
export AbstractTenantAdminStore, MemoryTenantAdminStore, SqlTenantAdminStore
export register_tenant!, rotate_api_key!, get_tenant_profile, update_tenant_settings!, list_users, create_user!, update_user!
export list_warehouses, get_warehouse, create_warehouse!, update_warehouse!, deactivate_warehouse!
export list_skus, get_sku, create_sku!, update_sku!, deactivate_sku!
export list_inventory_positions, update_inventory_position!, list_demand_history
export list_transfer_lanes, create_transfer_lane!, list_allocation_policies, create_allocation_policy!
export capture_simulation_input_snapshot, clean_demand_history, forecast_preview
export AllocationSolverConfig, solve_allocation_model, solver_outcome_decision, recommendation_net_value, generate_allocation_recommendations!
export create_simulation_run!, list_simulation_runs, get_simulation_run, cancel_simulation_run!
export list_recommendations, get_recommendation, approve_recommendation!, reject_recommendation!, expire_recommendation!, export_recommendation!, export_recommendation_csv, recommendation_view_model, build_recommendation_high_value_notification_event
export NotificationEventSpec, notification_event_spec, validate_notification_event!, notification_severity, resolve_notification_recipients, build_local_notification_event, create_local_notifications!, list_notifications, mark_notification_read!, mirror_notification_hub_outbox!
export expire_due_recommendations!, recommendation_expiry_due, run_due_recommendation_expiry!
export claim_next_simulation_run!, claim_next_simulation_run_for_system!, simulation_worker!, reap_stale_simulation_runs!, generate_demand_scenarios!
export run_daily_backtest!, run_daily_backtests!, daily_backtest_due, persist_policy_backtest_results!
export fetch_demand_history, build_job_service, run_due_daily_backtest!
export create_import_job!, get_import_result, claim_next_import_job!, process_import_job!, import_job_worker!
export render_login_page, render_protected_route_notice, render_dashboard_page, render_import_center_page, render_warehouses_page, render_skus_page, authenticate_ui_login!
export render_transfer_lanes_page, render_allocation_policies_page, render_tenant_settings_page, render_simulations_page, render_simulation_detail_page, render_recommendation_detail_page, render_notifications_page
export validate_demo_fixtures, run_setup_cli, run_seed_demo_cli
export Migration, MigrationRunResult, MigrationHealth, MemoryMigrationStore, SqlMigrationStore
export discover_migrations, run_migrations!, migration_health, run_migrate_cli
export start!, stop!

function start_runtime_jobs!(
    services::AppServices,
    config::AppConfig;
    start_jobs::Bool = false,
    import_store::Union{Nothing,AbstractTenantAdminStore} = nothing,
)::AppServices
    if start_jobs
        selected_import_store = import_store === nothing ? SqlTenantAdminStore(connect!(services.db)) : import_store
        start!(services.jobs; import_store = selected_import_store, import_config = config)
    end
    return services
end

function run_server!(;
    config::AppConfig = load_config(ENV),
    async::Bool = false,
    start_jobs::Bool = false,
    import_store::Union{Nothing,AbstractTenantAdminStore} = nothing,
    server_starter::Function = Genie.up,
    install_hook::Bool = true,
)
    services = build_services(config)
    register_routes!(services)
    start_runtime_jobs!(services, config; start_jobs = start_jobs, import_store = import_store)
    install_hook && install_shutdown_hook!(services)
    server_starter(config.app.port, config.app.host; async = async)
    return services
end

function main()
    load_env_file!()
    services = nothing
    try
        services = run_server!()
    catch err
        if services !== nothing
            shutdown!(services; stop_http = true)
        end
        rethrow(err)
    end
    return nothing
end

end # module
