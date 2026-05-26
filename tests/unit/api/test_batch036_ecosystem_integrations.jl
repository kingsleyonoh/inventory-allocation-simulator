using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH036_RUN_ID = UUID("e3600000-0000-4000-8000-000000000001")
const BATCH036_REC_ID = UUID("d3600000-0000-4000-8000-000000000001")

function batch036_config(; hub = "false", workflow = "false")
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => "postgres://placeholder",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch036.duckdb",
        "SESSION_SECRET" => "batch036-session-secret-placeholder",
        "METRICS_TOKEN" => "batch036-metrics-token-placeholder",
        "PUBLIC_BASE_URL" => "https://ias.example.test",
        "NOTIFICATION_HUB_ENABLED" => hub,
        "NOTIFICATION_HUB_URL" => "https://notify.example.test",
        "NOTIFICATION_HUB_API_KEY" => "placeholder-hub-key",
        "WORKFLOW_ENGINE_ENABLED" => workflow,
        "WORKFLOW_ENGINE_URL" => "https://workflows.example.test",
        "WORKFLOW_ENGINE_API_KEY" => "placeholder-workflow-key",
        "WORKFLOW_ALLOCATION_APPROVAL_WORKFLOW_ID" => "wf-allocation-approval",
    ))
end

function batch036_store()
    store = batch012_store()
    store.simulation_runs[BATCH036_RUN_ID] = Dict{Symbol,Any}(
        :id => BATCH036_RUN_ID,
        :tenant_id => BATCH012_TENANT_A,
        :policy_id => UUID("b0000000-0000-4000-8000-000000000001"),
        :name => "Batch 036 run",
        :status => "completed",
        :input_snapshot => Dict{String,Any}(),
        :scenario_count => 3,
        :started_at => DateTime(2026, 5, 6, 8),
        :completed_at => DateTime(2026, 5, 6, 9),
        :created_by_user_id => BATCH012_PLANNER_A.user_id,
        :created_at => DateTime(2026, 5, 6, 8),
        :updated_at => DateTime(2026, 5, 6, 9),
    )
    store.allocation_recommendations[BATCH036_REC_ID] = Dict{Symbol,Any}(
        :id => BATCH036_REC_ID,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => BATCH036_RUN_ID,
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
        :created_at => DateTime(2026, 5, 6, 9),
        :updated_at => DateTime(2026, 5, 6, 9),
    )
    return store
end

@testset "Batch 036 event envelope and notification payload validate required Hub tokens" begin
    store = batch036_store()
    config = batch036_config()
    payload = build_notification_payload(store, config, BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID)
    @test payload["tenant"]["display_name"] == "Northstar Supply"
    @test payload["tenant"]["contact"]["email"] == "ops+northstar@example.test"
    @test payload["recommendation"]["id"] == string(BATCH036_REC_ID)
    @test payload["recommendation"]["net_value_cents"] == 4100
    @test payload["recommendation"]["confidence_score"] == 0.86
    @test payload["recommendation"]["explanation_summary"] == "binding: lane_capacity; tradeoffs: transfer_cost"
    @test payload["action_url"] == "https://ias.example.test/recommendations/$(BATCH036_REC_ID)"

    envelope = build_event_envelope("allocation.high_value_found", BATCH012_TENANT_A, "evt-batch036-rec", payload)
    @test envelope["event_type"] == "allocation.high_value_found"
    @test envelope["event_id"] == "evt-batch036-rec"
    @test envelope["payload"] === payload
    @test_throws ApiError build_event_envelope("allocation.high_value_found", BATCH012_TENANT_A, "", payload)

    broken_store = batch036_store()
    broken_store.tenants[BATCH012_TENANT_A][:contact] = Dict{String,Any}()
    @test_throws ApiError build_notification_payload(broken_store, config, BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID)
    @test_throws ApiError build_notification_payload(store, config, BATCH012_TENANT_B, "allocation.high_value_found", BATCH036_REC_ID)
end

@testset "Batch 036 Notification Hub adapter is off by default and posts strict event envelope when enabled" begin
    store = batch036_store()
    disabled = enqueue_notification_hub_event!(store, batch036_config(), BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID; event_id = "evt-batch036-disabled")
    @test disabled.queued == false
    @test isempty(store.ecosystem_outbox)

    enabled = batch036_config(; hub = "true")
    queued = enqueue_notification_hub_event!(store, enabled, BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID; event_id = "evt-batch036-enabled")
    @test queued.queued == true
    row = store.ecosystem_outbox[UUID(queued.outbox_id)]
    @test row[:target] == "notification_hub"
    @test row[:status] == "queued"

    calls = Any[]
    result = dispatch_outbox_once!(store, enabled; now = DateTime(2026, 5, 6, 10), http_post = (url, body, headers; timeout_seconds = 10) -> begin
        push!(calls, (url = url, body = body, headers = headers, timeout_seconds = timeout_seconds))
        return (status = 202, body = "accepted")
    end)
    @test result.sent == 1
    @test row[:status] == "sent"
    @test only(calls).url == "https://notify.example.test/api/events"
    @test only(calls).body["event_type"] == "allocation.high_value_found"
    @test only(calls).body["payload"]["recommendation"]["net_value_cents"] == 4100
    @test only(calls).headers["Authorization"] == "Bearer placeholder-hub-key"
end

@testset "Batch 036 outbox dispatcher retries transient failures and dead-letters permanent failures" begin
    store = batch036_store()
    config = batch036_config(; hub = "true")
    transient = enqueue_notification_hub_event!(store, config, BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID; event_id = "evt-batch036-transient")
    row = store.ecosystem_outbox[UUID(transient.outbox_id)]
    failed = dispatch_outbox_once!(store, config; now = DateTime(2026, 5, 6, 10), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 503, body = "unavailable"))
    @test failed.failed == 1
    @test row[:status] == "failed"
    @test row[:attempts] == 1
    @test row[:next_attempt_at] == DateTime(2026, 5, 6, 10) + Second(2)
    @test occursin("503", row[:last_error])

    row[:status] = "queued"
    row[:next_attempt_at] = DateTime(2026, 5, 6, 10)
    row[:attempts] = 4
    dead = dispatch_outbox_once!(store, config; now = DateTime(2026, 5, 6, 10), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 500, body = "still down"))
    @test dead.dead_lettered == 1
    @test row[:status] == "dead_letter"
    @test row[:attempts] == 5

    store2 = batch036_store()
    permanent = enqueue_notification_hub_event!(store2, config, BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID; event_id = "evt-batch036-permanent")
    prow = store2.ecosystem_outbox[UUID(permanent.outbox_id)]
    permanent_result = dispatch_outbox_once!(store2, config; now = DateTime(2026, 5, 6, 10), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 400, body = "bad event"))
    @test permanent_result.dead_lettered == 1
    @test prow[:status] == "dead_letter"
end

@testset "Batch 036 Workflow Engine adapter posts manual execute payload without changing recommendation status" begin
    store = batch036_store()
    disabled = enqueue_workflow_execution!(store, batch036_config(), BATCH012_TENANT_A, BATCH036_REC_ID; event_id = "evt-batch036-workflow-disabled")
    @test disabled.queued == false
    @test isempty(store.ecosystem_outbox)

    config = batch036_config(; workflow = "true")
    queued = enqueue_workflow_execution!(store, config, BATCH012_TENANT_A, BATCH036_REC_ID; event_id = "evt-batch036-workflow")
    row = store.ecosystem_outbox[UUID(queued.outbox_id)]
    before_status = store.allocation_recommendations[BATCH036_REC_ID][:status]
    calls = Any[]
    result = dispatch_outbox_once!(store, config; now = DateTime(2026, 5, 6, 10), http_post = (url, body, headers; timeout_seconds = 10) -> begin
        push!(calls, (url = url, body = body, headers = headers))
        return (status = 200, body = "ok")
    end)
    @test result.sent == 1
    @test row[:status] == "sent"
    @test store.allocation_recommendations[BATCH036_REC_ID][:status] == before_status
    @test only(calls).url == "https://workflows.example.test/api/workflows/wf-allocation-approval/execute"
    @test only(calls).body["trigger_data"]["recommendation"]["id"] == string(BATCH036_REC_ID)
    @test only(calls).headers["X-API-Key"] == "placeholder-workflow-key"
end

@testset "Batch 036 SQL outbox dispatcher is wired for durable worker delivery" begin
    @test hasmethod(dispatch_outbox_once!, Tuple{SqlTenantAdminStore, AppConfig})
    @test hasmethod(outbox_dispatcher!, Tuple{SqlTenantAdminStore, AppConfig})
    worker_source = replace(read(joinpath(project_root(), "src", "jobs", "worker.jl"), String), "\r\n" => "\n")
    @test occursin("run_due_daily_backtest!(service, service.simulation_store, service.import_config, TenantContext[])\n            dispatch_outbox_once!(service.simulation_store, service.import_config)", worker_source)
end

@testset "Batch 036 outbox dispatch benchmark proves queued events drain under 60 seconds" begin
    store = batch036_store()
    config = batch036_config(; hub = "true")
    for i in 1:25
        enqueue_notification_hub_event!(store, config, BATCH012_TENANT_A, "allocation.high_value_found", BATCH036_REC_ID; event_id = "evt-batch036-bench-$i")
    end
    result = benchmark_outbox_dispatch_60s!(store, config; now = DateTime(2026, 5, 6, 10), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 202, body = "accepted"))
    @test result.sent == 25
    @test result.within_60_seconds == true
    @test all(row -> row[:status] == "sent", values(store.ecosystem_outbox))
end
