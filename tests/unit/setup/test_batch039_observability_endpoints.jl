using Test
using Dates
using UUIDs

function batch039_config(; metrics_token = "internal-metrics-token")
    InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/batch039-test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => metrics_token,
        "APP_PORT" => "8017",
    ))
end

@testset "Batch 039 observability endpoints and readiness contracts" begin
    routes = InventoryAllocationSimulator.route_definitions()
    route_pairs = Set((route.method, route.path) for route in routes)

    @test (:GET, "/metrics") in route_pairs
    @test (:GET, "/health") in route_pairs
    @test (:GET, "/health/db") in route_pairs
    @test (:GET, "/health/ready") in route_pairs

    config = batch039_config()
    services = InventoryAllocationSimulator.build_services(config)

    @test InventoryAllocationSimulator.metrics_authorized(services, Dict{String,String}()) == false
    @test InventoryAllocationSimulator.metrics_authorized(services, Dict("X-Metrics-Token" => "wrong")) == false
    @test InventoryAllocationSimulator.metrics_authorized(services, Dict("X-Metrics-Token" => "internal-metrics-token")) == true
    @test InventoryAllocationSimulator.metrics_authorized(services, Dict("Authorization" => "Bearer internal-metrics-token")) == true

    tenant_id = uuid4()
    store = InventoryAllocationSimulator.MemoryTenantAdminStore([], [];
        simulation_runs = [
            (id = uuid4(), tenant_id = tenant_id, policy_id = uuid4(), name = "failed", status = "failed", input_snapshot = Dict{String,Any}(), scenario_count = 0, started_at = DateTime(2026, 5, 26, 11, 55, 0), completed_at = DateTime(2026, 5, 26, 11, 57, 30), error_message = "solver failed", created_by_user_id = nothing, idempotency_key = nothing, created_at = DateTime(2026, 5, 26, 11, 55, 0), updated_at = DateTime(2026, 5, 26, 11, 57, 30)),
            (id = uuid4(), tenant_id = tenant_id, policy_id = uuid4(), name = "completed", status = "completed", input_snapshot = Dict{String,Any}(), scenario_count = 0, started_at = DateTime(2026, 5, 26, 11, 58, 0), completed_at = DateTime(2026, 5, 26, 11, 59, 30), error_message = nothing, created_by_user_id = nothing, idempotency_key = nothing, created_at = DateTime(2026, 5, 26, 11, 58, 0), updated_at = DateTime(2026, 5, 26, 11, 59, 30)),
        ],
        import_jobs = [(id = uuid4(), tenant_id = tenant_id, import_type = "inventory", status = "failed", original_filename = "bad.csv", file_path = "bad.csv", row_count = 10, error_report = [], committed_rows = 0)],
        ecosystem_outbox = [(id = uuid4(), tenant_id = tenant_id, event_type = "integration.failed", event_id = "evt-1", payload = Dict{String,Any}(), target = "notification_hub", status = "dead_letter", attempts = 5, next_attempt_at = DateTime(2026, 5, 26, 12, 0, 0), last_error = "HTTP 500", created_at = DateTime(2026, 5, 26, 11, 0, 0), updated_at = DateTime(2026, 5, 26, 11, 59, 0))],
    )
    metrics = InventoryAllocationSimulator.collect_operational_metrics(store)
    body = InventoryAllocationSimulator.prometheus_metrics_text(services; timestamp = DateTime(2026, 5, 26, 12, 0, 0), metrics = metrics)
    @test occursin("# HELP inventory_allocation_app_up", body)
    @test occursin("# TYPE inventory_allocation_app_up gauge", body)
    @test occursin("inventory_allocation_app_up 1", body)
    @test occursin("inventory_allocation_build_info", body)
    @test occursin("inventory_simulation_runs_total 2", body)
    @test occursin("inventory_simulation_failures_total 1", body)
    @test occursin("inventory_import_jobs_total 1", body)
    @test occursin("inventory_import_failures_total 1", body)
    @test occursin("inventory_outbox_dead_letters_total 1", body)
    @test occursin("inventory_database_up 1", body)
    @test occursin("inventory_solver_duration_seconds_bucket{le=\"120\"} 1", body)
    @test occursin("inventory_solver_duration_seconds_bucket{le=\"+Inf\"} 2", body)
    @test occursin("inventory_solver_duration_seconds_count 2", body)
    @test !occursin("internal-metrics-token", body)

    current_store = InventoryAllocationSimulator.MemoryMigrationStore()
    mktempdir() do dir
        write(joinpath(dir, "001_ready.up.sql"), "SELECT 1;\n")
        InventoryAllocationSimulator.run_migrations!(current_store, dir; direction = :up)
        ready = InventoryAllocationSimulator.ready_health_response(services; migration_dir = dir, migration_store = current_store)
        @test ready.status == "ready"
        @test ready.database.status == "ok"
        @test ready.database.migrations.status == :current

        pending_store = InventoryAllocationSimulator.MemoryMigrationStore()
        not_ready = InventoryAllocationSimulator.ready_health_response(services; migration_dir = dir, migration_store = pending_store)
        @test not_ready.status == "not_ready"
        @test not_ready.database.status == "pending"
        @test not_ready.database.migrations.pending_versions == ["001"]
    end
end

@testset "Batch 039 local error and analytics persistence contracts" begin
    @test InventoryAllocationSimulator.normalized_observability_event_type("simulation failed") == "simulation_failed"
    @test InventoryAllocationSimulator.normalized_observability_event_type("Approval.Completed") == "approval_completed"
    @test InventoryAllocationSimulator.OBSERVABILITY_KEY_EVENTS == Set([
        "tenant_registered",
        "import_completed",
        "simulation_started",
        "simulation_completed",
        "recommendation_approved",
        "recommendation_exported",
    ])

    error_event = InventoryAllocationSimulator.build_local_error_event(
        "simulation.failure";
        tenant_id = nothing,
        source = "simulation_worker",
        message = "solver failed",
        request_id = "req-batch039",
        details = Dict("run_id" => "run-1"),
        occurred_at = DateTime(2026, 5, 26, 12, 1, 0),
    )
    @test haskey(error_event, :id)
    @test error_event[:event_type] == "simulation.failure"
    @test error_event[:source] == "simulation_worker"
    @test error_event[:message] == "solver failed"
    @test error_event[:request_id] == "req-batch039"
    @test error_event[:details]["run_id"] == "run-1"

    analytics_event = InventoryAllocationSimulator.build_local_analytics_event(
        "simulation started";
        tenant_id = nothing,
        user_id = nothing,
        properties = Dict("scenario_count" => 100),
        occurred_at = DateTime(2026, 5, 26, 12, 2, 0),
    )
    @test analytics_event[:event_type] == "simulation_started"
    @test analytics_event[:properties]["scenario_count"] == 100

    @test_throws InventoryAllocationSimulator.ApiError InventoryAllocationSimulator.build_local_error_event(
        ""; source = "simulation_worker", message = "solver failed"
    )
    @test_throws InventoryAllocationSimulator.ApiError InventoryAllocationSimulator.build_local_analytics_event(
        ""; properties = Dict{String,Any}()
    )
end

@testset "Batch 039 alerting, migrations, and optional PostHog config are documented" begin
    root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    up = read(joinpath(root, "migrations", "008_observability_events.up.sql"), String)
    down = read(joinpath(root, "migrations", "008_observability_events.down.sql"), String)
    alerts = read(joinpath(root, "config", "prometheus", "alerts.yml"), String)
    env_example = read(joinpath(root, ".env.example"), String)

    for table in ["local_error_events", "local_analytics_events"]
        @test occursin("CREATE TABLE IF NOT EXISTS $table", up)
        @test occursin("tenant_id UUID", up)
        @test occursin("DROP TABLE IF EXISTS $table", down)
    end

    @test occursin("InventorySimulationFailures", alerts)
    @test occursin("increase(inventory_simulation_failures_total[30m]) / clamp_min(increase(inventory_simulation_runs_total[30m]), 1) > 0.10", alerts)
    @test occursin("severity: critical", alerts)
    @test occursin("InventoryImportFailures", alerts)
    @test occursin("increase(inventory_import_failures_total[30m]) / clamp_min(increase(inventory_import_jobs_total[30m]), 1) > 0.20", alerts)
    @test occursin("InventoryOutboxDeadLetters", alerts)
    @test occursin("increase(inventory_outbox_dead_letters_total[30m]) > 5", alerts)
    @test occursin("InventoryDatabaseOutage", alerts)
    @test occursin("InventorySolverP95High", alerts)
    @test occursin("increase(inventory_solver_duration_seconds_count[30m]) >= 3", alerts)

    @test occursin("POSTHOG_ENABLED=false", env_example)
    @test occursin("POSTHOG_API_KEY=", env_example)
    @test occursin("SENTRY_DSN=", env_example)
end
