using Dates

struct AppRuntimeConfig
    env::String
    host::String
    port::Int
    public_base_url::String
    log_level::String
    log_requests::Bool
end

struct DatabaseConfig
    url::String
    redis_url::String
    duckdb_path::String
end

struct TenantConfig
    self_registration_enabled::Bool
    api_key_prefix::String
    default_tenant_name::String
    default_admin_email::String
    session_secret::String
end

struct ImportConfig
    max_import_mb::Int
    partial_commit::Bool
    upload_storage_path::String
end

struct SimulationConfig
    default_scenario_count::Int
    min_history_periods::Int
    forecast_lookback_days::Int
    solver_timeout_seconds::Int
    max_solver_gap::Float64
    min_transfer_units::Int
    run_stale_after_minutes::Int
    idempotency_window_hours::Int
    recommendation_expiry_days::Int
    require_rejection_reason::Bool
end

struct IntegrationConfig
    notification_hub_enabled::Bool
    notification_hub_url::String
    notification_hub_api_key::String
    workflow_engine_enabled::Bool
    workflow_engine_url::String
    workflow_engine_api_key::String
    workflow_allocation_approval_workflow_id::String
    delivery_gateway_enabled::Bool
    delivery_gateway_url::String
    delivery_gateway_api_key::String
    delivery_redis_url::String
end

struct ObservabilityConfig
    sentry_dsn::String
    metrics_token::String
end

struct AppConfig
    app::AppRuntimeConfig
    database::DatabaseConfig
    tenant::TenantConfig
    imports::ImportConfig
    simulation::SimulationConfig
    integrations::IntegrationConfig
    observability::ObservabilityConfig
end

function project_root()::String
    return normpath(joinpath(@__DIR__, ".."))
end

function _env_get(env, key::String, default::String = "")::String
    return strip(string(get(env, key, default)))
end

function _required(env, key::String)::String
    value = _env_get(env, key)
    isempty(value) && throw(ArgumentError("$key is required"))
    return value
end

function _parse_bool(value::String, key::String)::Bool
    lowered = lowercase(strip(value))
    if lowered in ("true", "1", "yes")
        return true
    elseif lowered in ("false", "0", "no")
        return false
    end
    throw(ArgumentError("$key must be true or false"))
end

function _parse_int(value::String, key::String; min::Int = typemin(Int), max::Int = typemax(Int))::Int
    parsed = tryparse(Int, strip(value))
    if parsed === nothing || parsed < min || parsed > max
        throw(ArgumentError("$key must be an integer from $min to $max"))
    end
    return parsed
end

function _parse_float(value::String, key::String; min::Float64, max::Float64)::Float64
    parsed = tryparse(Float64, strip(value))
    if parsed === nothing || parsed < min || parsed > max
        throw(ArgumentError("$key must be a number from $min to $max"))
    end
    return parsed
end

function parse_port(value::AbstractString)::Int
    return _parse_int(String(value), "APP_PORT"; min = 1, max = 65535)
end

function _load_runtime_config(env)::AppRuntimeConfig
    return AppRuntimeConfig(
        _env_get(env, "APP_ENV", "development"),
        _env_get(env, "APP_HOST", DEFAULT_HOST),
        parse_port(_env_get(env, "APP_PORT", string(DEFAULT_PORT))),
        _env_get(env, "PUBLIC_BASE_URL", "http://localhost:8000"),
        _env_get(env, "LOG_LEVEL", "info"),
        _parse_bool(_env_get(env, "GENIE_LOG_REQUESTS", "true"), "GENIE_LOG_REQUESTS"),
    )
end

function _load_database_config(env)::DatabaseConfig
    return DatabaseConfig(
        _required(env, "DATABASE_URL"),
        _required(env, "REDIS_URL"),
        _required(env, "DUCKDB_PATH"),
    )
end

function _load_tenant_config(env)::TenantConfig
    return TenantConfig(
        _parse_bool(_env_get(env, "SELF_REGISTRATION_ENABLED", "true"), "SELF_REGISTRATION_ENABLED"),
        _env_get(env, "API_KEY_PREFIX", "ias_live"),
        _env_get(env, "DEFAULT_TENANT_NAME", "Default"),
        _env_get(env, "DEFAULT_ADMIN_EMAIL", "admin@example.com"),
        _required(env, "SESSION_SECRET"),
    )
end

function _load_import_config(env)::ImportConfig
    return ImportConfig(
        _parse_int(_env_get(env, "MAX_IMPORT_MB", "25"), "MAX_IMPORT_MB"; min = 1, max = 1024),
        _parse_bool(_env_get(env, "IMPORT_PARTIAL_COMMIT", "false"), "IMPORT_PARTIAL_COMMIT"),
        _env_get(env, "UPLOAD_STORAGE_PATH", "./data/uploads"),
    )
end

function _load_simulation_config(env)::SimulationConfig
    return SimulationConfig(
        _parse_int(_env_get(env, "DEFAULT_SCENARIO_COUNT", "100"), "DEFAULT_SCENARIO_COUNT"; min = 1, max = 10000),
        _parse_int(_env_get(env, "MIN_HISTORY_PERIODS", "8"), "MIN_HISTORY_PERIODS"; min = 1, max = 10000),
        _parse_int(_env_get(env, "FORECAST_LOOKBACK_DAYS", "180"), "FORECAST_LOOKBACK_DAYS"; min = 1, max = 3650),
        _parse_int(_env_get(env, "SOLVER_TIMEOUT_SECONDS", "120"), "SOLVER_TIMEOUT_SECONDS"; min = 1, max = 86400),
        _parse_float(_env_get(env, "MAX_SOLVER_GAP", "0.05"), "MAX_SOLVER_GAP"; min = 0.0, max = 1.0),
        _parse_int(_env_get(env, "MIN_TRANSFER_UNITS", "1"), "MIN_TRANSFER_UNITS"; min = 1, max = 1000000),
        _parse_int(_env_get(env, "RUN_STALE_AFTER_MINUTES", "30"), "RUN_STALE_AFTER_MINUTES"; min = 1, max = 10080),
        _parse_int(_env_get(env, "SIMULATION_IDEMPOTENCY_WINDOW_HOURS", "24"), "SIMULATION_IDEMPOTENCY_WINDOW_HOURS"; min = 1, max = 8760),
        _parse_int(_env_get(env, "RECOMMENDATION_EXPIRY_DAYS", "7"), "RECOMMENDATION_EXPIRY_DAYS"; min = 1, max = 3650),
        _parse_bool(_env_get(env, "REQUIRE_REJECTION_REASON", "true"), "REQUIRE_REJECTION_REASON"),
    )
end

function _load_integration_config(env)::IntegrationConfig
    return IntegrationConfig(
        _parse_bool(_env_get(env, "NOTIFICATION_HUB_ENABLED", "false"), "NOTIFICATION_HUB_ENABLED"),
        _env_get(env, "NOTIFICATION_HUB_URL", ""),
        _env_get(env, "NOTIFICATION_HUB_API_KEY", ""),
        _parse_bool(_env_get(env, "WORKFLOW_ENGINE_ENABLED", "false"), "WORKFLOW_ENGINE_ENABLED"),
        _env_get(env, "WORKFLOW_ENGINE_URL", ""),
        _env_get(env, "WORKFLOW_ENGINE_API_KEY", ""),
        _env_get(env, "WORKFLOW_ALLOCATION_APPROVAL_WORKFLOW_ID", ""),
        _parse_bool(_env_get(env, "DELIVERY_GATEWAY_ENABLED", "false"), "DELIVERY_GATEWAY_ENABLED"),
        _env_get(env, "DELIVERY_GATEWAY_URL", ""),
        _env_get(env, "DELIVERY_GATEWAY_API_KEY", ""),
        _env_get(env, "DELIVERY_REDIS_URL", ""),
    )
end

function _load_observability_config(env)::ObservabilityConfig
    return ObservabilityConfig(
        _env_get(env, "SENTRY_DSN", ""),
        _required(env, "METRICS_TOKEN"),
    )
end

function load_config(env = ENV)::AppConfig
    return AppConfig(
        _load_runtime_config(env),
        _load_database_config(env),
        _load_tenant_config(env),
        _load_import_config(env),
        _load_simulation_config(env),
        _load_integration_config(env),
        _load_observability_config(env),
    )
end

function load_env_file!(path::AbstractString = joinpath(project_root(), ".env"); override::Bool = false)::Int
    isfile(path) || return 0
    loaded = 0
    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#") || !occursin("=", line)) && continue
        key, value = split(line, "="; limit = 2)
        key = strip(key)
        value = strip(value)
        if override || !haskey(ENV, key)
            ENV[key] = value
            loaded += 1
        end
    end
    return loaded
end
