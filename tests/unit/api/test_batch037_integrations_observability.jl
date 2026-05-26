using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

const BATCH037_RUN_ID = UUID("e3700000-0000-4000-8000-000000000001")
const BATCH037_REC_ID = UUID("d3700000-0000-4000-8000-000000000001")
const BATCH037_ADAPTER_ID = UUID("a3700000-0000-4000-8000-000000000001")

function batch037_config(; hub = "false", workflow = "false", delivery = "false")
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => "postgres://placeholder",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch037.duckdb",
        "SESSION_SECRET" => "batch037-session-secret-placeholder",
        "METRICS_TOKEN" => "batch037-metrics-token-placeholder",
        "PUBLIC_BASE_URL" => "https://ias.example.test",
        "NOTIFICATION_HUB_ENABLED" => hub,
        "NOTIFICATION_HUB_URL" => "https://notify.example.test",
        "NOTIFICATION_HUB_API_KEY" => "placeholder-hub-key",
        "WORKFLOW_ENGINE_ENABLED" => workflow,
        "WORKFLOW_ENGINE_URL" => "https://workflows.example.test",
        "WORKFLOW_ENGINE_API_KEY" => "placeholder-workflow-key",
        "WORKFLOW_ALLOCATION_APPROVAL_WORKFLOW_ID" => "wf-allocation-approval",
        "DELIVERY_GATEWAY_ENABLED" => delivery,
        "DELIVERY_GATEWAY_URL" => "https://delivery.example.test",
        "DELIVERY_GATEWAY_API_KEY" => "placeholder-delivery-key",
        "DELIVERY_REDIS_URL" => "redis://localhost:6379/1",
    ))
end

function batch037_store()
    store = batch012_store()
    store.simulation_runs[BATCH037_RUN_ID] = Dict{Symbol,Any}(
        :id => BATCH037_RUN_ID,
        :tenant_id => BATCH012_TENANT_A,
        :policy_id => UUID("b0000000-0000-4000-8000-000000000001"),
        :name => "Batch 037 run",
        :status => "completed",
        :input_snapshot => Dict{String,Any}(),
        :scenario_count => 3,
        :started_at => DateTime(2026, 5, 7, 8),
        :completed_at => DateTime(2026, 5, 7, 9),
        :created_by_user_id => BATCH012_PLANNER_A.user_id,
        :created_at => DateTime(2026, 5, 7, 8),
        :updated_at => DateTime(2026, 5, 7, 9),
    )
    store.allocation_recommendations[BATCH037_REC_ID] = Dict{Symbol,Any}(
        :id => BATCH037_REC_ID,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => BATCH037_RUN_ID,
        :from_warehouse_id => UUID("10000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => UUID("10000000-0000-4000-8000-000000000002"),
        :sku_id => UUID("30000000-0000-4000-8000-000000000001"),
        :transfer_units => 12.0,
        :expected_stockout_reduction_units => 8.0,
        :expected_margin_gain_cents => 5200,
        :transfer_cost_cents => 1100,
        :net_value_cents => 4100,
        :confidence_score => 0.86,
        :explanation => Dict("binding_constraints" => ["lane_capacity"], "scenario_sensitivity" => Dict("scenario_count" => 3), "accepted_tradeoffs" => ["transfer_cost"]),
        :status => "approved",
        :created_at => DateTime(2026, 5, 7, 9),
        :updated_at => DateTime(2026, 5, 7, 9),
    )
    return store
end

@testset "Batch 037 Workflow Engine failures dead-letter without mutating recommendation truth" begin
    store = batch037_store()
    config = batch037_config(; workflow = "true")
    queued = enqueue_workflow_execution!(store, config, BATCH012_TENANT_A, BATCH037_REC_ID; event_id = "evt-batch037-workflow-fails")
    row = store.ecosystem_outbox[UUID(queued.outbox_id)]
    row[:attempts] = 4
    before_status = store.allocation_recommendations[BATCH037_REC_ID][:status]
    result = dispatch_outbox_once!(store, config; now = DateTime(2026, 5, 7, 10), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 503, body = "workflow down"))
    @test result.dead_lettered == 1
    @test row[:status] == "dead_letter"
    @test occursin("503", row[:last_error])
    @test store.allocation_recommendations[BATCH037_REC_ID][:status] == before_status
end

@testset "Batch 037 Delivery Gateway ETA freshness is feature-flagged and validates REST and Redis fixtures" begin
    disabled = delivery_eta_freshness(batch037_config(), "transfer-1"; now = DateTime(2026, 5, 7, 12))
    @test disabled.enabled == false
    @test disabled.status == "disabled"

    calls = Any[]
    rest = delivery_eta_freshness(batch037_config(; delivery = "true"), "transfer-1"; now = DateTime(2026, 5, 7, 12), http_get = (url, headers; timeout_seconds = 10) -> begin
        push!(calls, (url = url, headers = headers, timeout_seconds = timeout_seconds))
        (status = 200, body = JSON3.write(Dict("eta_at" => "2026-05-07T13:30:00", "observed_at" => "2026-05-07T11:45:00", "status" => "in_transit")))
    end)
    @test rest.enabled == true
    @test rest.status == "fresh"
    @test rest.minutes_old == 15
    @test only(calls).url == "https://delivery.example.test/api/etas/transfer-1"
    @test only(calls).headers["X-API-Key"] == "placeholder-delivery-key"

    stale = delivery_eta_freshness_from_redis_fixture(Dict("eta_at" => "2026-05-07T13:30:00", "observed_at" => "2026-05-07T10:00:00", "status" => "in_transit"); now = DateTime(2026, 5, 7, 12), max_age_minutes = 60)
    @test stale.status == "stale"
    @test stale.minutes_old == 120

    @test_throws ApiError delivery_eta_freshness_from_redis_fixture(Dict("observed_at" => "2026-05-07T10:00:00"); now = DateTime(2026, 5, 7, 12))
end

@testset "Batch 037 integration settings page renders adapter flags and health states" begin
    controller_source = read(joinpath(InventoryAllocationSimulator.project_root(), "src", "web", "controllers", "ui_integrations_page.jl"), String)
    @test occursin("authorize!(ctx, \"configure\", \"integration\")", controller_source)

    config = batch037_config(; workflow = "true", delivery = "true")
    statuses = integration_adapter_statuses(config; now = DateTime(2026, 5, 7, 12), http_get = (url, headers; timeout_seconds = 10) -> begin
        occursin("delivery", url) ? (status = 503, body = "down") : (status = 200, body = "ok")
    end)
    html = render_integration_settings_page(config, statuses)
    @test occursin("Integration settings", html)
    @test occursin("Notification Hub", html)
    @test occursin("Workflow Engine", html)
    @test occursin("Delivery Tracking Gateway", html)
    @test occursin("Adapter disabled", html)
    @test occursin("Adapter failed", html)
    @test occursin("aria-label=\"Integration adapter health\"", html)

    routes = route_definitions()
    @test any(route -> route.path == "/integrations" && route.method == :GET, routes)
    @test any(route -> route.path == "/settings/integrations" && route.method == :GET, routes)
end

@testset "Batch 037 integration API status and test routes require admin configuration authorization" begin
    routes = route_definitions()
    @test any(route -> route.path == "/api/integrations/status" && route.method == :GET, routes)
    @test any(route -> route.path == "/api/integrations/test" && route.method == :POST, routes)

    controller_source = read(joinpath(InventoryAllocationSimulator.project_root(), "src", "web", "controllers", "integration_controller.jl"), String)
    @test occursin("handle_integration_status", controller_source)
    @test occursin("handle_test_integration", controller_source)
    @test occursin("_enforce_route_rate_limit!(services, \"GET\", \"/api/integrations/status\")", controller_source)
    @test occursin("_enforce_route_rate_limit!(services, \"POST\", \"/api/integrations/test\")", controller_source)
    @test count(occursin.(Ref("authorize!(ctx, \"configure\", \"integration\")"), split(controller_source, '\n'))) >= 2
    @test InventoryAllocationSimulator._integration_test_payload(batch037_config(), "notification_hub").status == "disabled"
    @test_throws ApiError InventoryAllocationSimulator._integration_test_payload(batch037_config(), "unknown_adapter")
end

@testset "Batch 037 integration status probe emits adapter-failure notifications" begin
    worker_source = read(joinpath(InventoryAllocationSimulator.project_root(), "src", "jobs", "worker.jl"), String)
    @test occursin("probe_integration_status!", worker_source)

    store = batch037_store()
    config = batch037_config(; workflow = "true", delivery = "true")
    result = probe_integration_status!(store, config, BATCH012_TENANT_A; now = DateTime(2026, 5, 7, 12), http_get = (url, headers; timeout_seconds = 10) -> (status = 503, body = "unavailable"))
    @test result.failed_count == 2
    @test length(store.local_notifications) == 1
    note = only(values(store.local_notifications))
    @test note[:event_type] == "integration.adapter_failed"
    @test note[:source_record_type] == "integration_adapter"
    @test note[:payload]["failed_adapters"] == ["workflow_engine", "delivery_gateway"]
    @test occursin("Workflow Engine", note[:body])

    again = probe_integration_status!(store, config, BATCH012_TENANT_A; now = DateTime(2026, 5, 7, 12), http_get = (url, headers; timeout_seconds = 10) -> (status = 503, body = "unavailable"))
    @test again.notifications_created == 0
end

@testset "Batch 037 structured JSON logs carry request IDs without leaking adapter keys" begin
    controller_source = read(joinpath(InventoryAllocationSimulator.project_root(), "src", "web", "controllers", "tenant_admin_controller.jl"), String)
    outbox_source = read(joinpath(InventoryAllocationSimulator.project_root(), "src", "jobs", "outbox_jobs.jl"), String)
    @test occursin("request_id_from_headers", controller_source)
    @test occursin("endpoint_error_response(err; request_id", controller_source)
    @test occursin("structured_log_json", outbox_source)
    @test occursin("request_id::Union{Nothing,AbstractString}", outbox_source)
    @test occursin("outbox dispatcher completed", outbox_source)

    rid = request_id_from_headers(Dict("X-Request-ID" => "req-batch037"))
    @test rid == "req-batch037"
    generated = request_id_from_headers(Dict{String,String}())
    @test startswith(generated, "req_")

    line = structured_log_json("info", "outbox dispatch", request_id = rid, log_module = "outbox", tenant_id = string(BATCH012_TENANT_A), fields = Dict("adapter" => "workflow_engine", "api_key" => "placeholder-workflow-key"))
    parsed = JSON3.read(line)
    @test parsed[:level] == "info"
    @test parsed[:request_id] == "req-batch037"
    @test parsed[:module] == "outbox"
    @test !haskey(parsed, :api_key)
    @test !occursin("placeholder-workflow-key", line)

    status, body, headers = endpoint_error_response(ApiError("VALIDATION_ERROR", "bad"; status = 400); request_id = rid)
    @test status == 400
    @test headers["X-Request-ID"] == rid
    @test JSON3.read(body)[:error][:request_id] == rid
end
