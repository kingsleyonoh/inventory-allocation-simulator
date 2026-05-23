module InventoryAllocationSimulator

using Genie

const DEFAULT_HOST = "0.0.0.0"
const DEFAULT_PORT = 8000

include("../config/app.jl")
include("db/connection.jl")
include("jobs/worker.jl")
include("observability/logging.jl")
include("services.jl")
include("tenant/bootstrap.jl")
include("imports/demo_seed.jl")
include("../config/routes.jl")

export AppConfig, AppServices, SetupResult
export load_config, load_env_file!, project_root, parse_port
export build_services, run_server!, main, register_routes!, route_definitions, health_response
export first_run_setup!, generate_api_key, hash_api_key, AbstractSetupStore, count_tenants, insert_tenant!, insert_admin_user!
export validate_demo_fixtures, run_setup_cli, run_seed_demo_cli

function run_server!(; config::AppConfig = load_config(ENV), async::Bool = false)
    services = build_services(config)
    register_routes!(services)
    Genie.up(config.app.port, config.app.host; async = async)
    return services
end

function main()
    load_env_file!()
    run_server!()
    return nothing
end

end # module
