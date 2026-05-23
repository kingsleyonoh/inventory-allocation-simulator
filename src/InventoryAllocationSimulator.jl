module InventoryAllocationSimulator

using Genie

const DEFAULT_HOST = "0.0.0.0"
const DEFAULT_PORT = 8000

include("../config/app.jl")
include("db/connection.jl")
include("db/migrations.jl")
include("cache/request_cache.jl")
include("jobs/worker.jl")
include("observability/logging.jl")
include("services.jl")
include("tenant/bootstrap.jl")
include("imports/demo_seed.jl")
include("../config/routes.jl")

export AppConfig, AppServices, SetupResult
export load_config, load_env_file!, project_root, parse_port
export build_services, shutdown!, install_shutdown_hook!, run_server!, main, register_routes!, route_definitions, health_response, db_health_response
export RequestCache, get_cached!, cache_keys
export first_run_setup!, generate_api_key, hash_api_key, AbstractSetupStore, count_tenants, insert_tenant!, insert_admin_user!
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
