using Test

@testset "Environment configuration loader validates PRD section 14" begin
    env = Dict(
        "APP_ENV" => "test",
        "APP_HOST" => "127.0.0.1",
        "APP_PORT" => "8099",
        "PUBLIC_BASE_URL" => "http://127.0.0.1:8099",
        "LOG_LEVEL" => "debug",
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-config.duckdb",
        "SELF_REGISTRATION_ENABLED" => "false",
        "API_KEY_PREFIX" => "ias_test",
        "DEFAULT_TENANT_NAME" => "Demo Tenant",
        "DEFAULT_ADMIN_EMAIL" => "admin@example.com",
        "SESSION_SECRET" => "development-session-secret",
        "MAX_IMPORT_MB" => "10",
        "IMPORT_PARTIAL_COMMIT" => "true",
        "UPLOAD_STORAGE_PATH" => "./data/uploads",
        "DEFAULT_SCENARIO_COUNT" => "12",
        "MIN_HISTORY_PERIODS" => "4",
        "FORECAST_LOOKBACK_DAYS" => "90",
        "SOLVER_TIMEOUT_SECONDS" => "45",
        "MAX_SOLVER_GAP" => "0.02",
        "MIN_TRANSFER_UNITS" => "2",
        "RUN_STALE_AFTER_MINUTES" => "15",
        "SIMULATION_IDEMPOTENCY_WINDOW_HOURS" => "6",
        "RECOMMENDATION_EXPIRY_DAYS" => "3",
        "REQUIRE_REJECTION_REASON" => "false",
        "NOTIFICATION_HUB_ENABLED" => "false",
        "WORKFLOW_ENGINE_ENABLED" => "false",
        "DELIVERY_GATEWAY_ENABLED" => "false",
        "SENTRY_DSN" => "",
        "METRICS_TOKEN" => "metrics-token-placeholder"
    )

    config = InventoryAllocationSimulator.load_config(env)

    @test config.app.env == "test"
    @test config.app.port == 8099
    @test config.database.url == env["DATABASE_URL"]
    @test config.database.redis_url == env["REDIS_URL"]
    @test config.database.duckdb_path == "./data/test-config.duckdb"
    @test config.tenant.self_registration_enabled == false
    @test config.tenant.api_key_prefix == "ias_test"
    @test config.imports.max_import_mb == 10
    @test config.imports.partial_commit == true
    @test config.simulation.default_scenario_count == 12
    @test config.simulation.max_solver_gap == 0.02
    @test config.integrations.notification_hub_enabled == false
    @test config.observability.metrics_token == "metrics-token-placeholder"
end

@testset "Environment configuration rejects unsafe or malformed values" begin
    @test_throws ArgumentError InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test.duckdb",
        "SESSION_SECRET" => "",
        "METRICS_TOKEN" => "metrics-token-placeholder"
    ))

    @test_throws ArgumentError InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
        "APP_PORT" => "70000"
    ))

    @test_throws ArgumentError InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
        "IMPORT_PARTIAL_COMMIT" => "sometimes"
    ))
end

@testset "Dependency injection wires configured services without opening network connections" begin
    config = InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-wiring.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
        "APP_PORT" => "8010"
    ))

    services = InventoryAllocationSimulator.build_services(config)

    @test services.config === config
    @test services.db.url == config.database.url
    @test services.cache.url == config.database.redis_url
    @test services.analytics.path == config.database.duckdb_path
    @test services.jobs.configured == true
    @test services.observability.log_level == config.app.log_level
    @test services.observability.metrics_token == config.observability.metrics_token
    @test services.rate_limiter isa InventoryAllocationSimulator.MemoryRateLimiter
end

@testset "Route registration exposes production health route through the registry" begin
    definitions = InventoryAllocationSimulator.route_definitions()

    @test any(def -> def.method == :GET && def.path == "/health", definitions)
    @test InventoryAllocationSimulator.health_response().status == "ok"
end
