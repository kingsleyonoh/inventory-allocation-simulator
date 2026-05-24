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
include("jobs/worker.jl")
include("observability/logging.jl")
include("services.jl")
include("web/controllers/tenant_admin_controller.jl")
include("imports/demo_seed.jl")
include("../config/routes.jl")

export AppConfig, AppServices, SetupResult
export load_config, load_env_file!, project_root, parse_port
export build_services, shutdown!, install_shutdown_hook!, run_server!, main, register_routes!, route_definitions, health_response, db_health_response
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
export register_tenant!, get_tenant_profile, update_tenant_settings!, list_users, create_user!, update_user!
export validate_demo_fixtures, run_setup_cli, run_seed_demo_cli
export Migration, MigrationRunResult, MigrationHealth, MemoryMigrationStore, SqlMigrationStore
export discover_migrations, run_migrations!, migration_health, run_migrate_cli
export start!, stop!

function run_server!(; config::AppConfig = load_config(ENV), async::Bool = false, start_jobs::Bool = false)
    services = build_services(config)
    register_routes!(services)
    start_jobs && start!(services.jobs)
    install_shutdown_hook!(services)
    Genie.up(config.app.port, config.app.host; async = async)
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
