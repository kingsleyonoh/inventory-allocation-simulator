using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH055_RUN_ID = UUID("e5500000-0000-4000-8000-000000000001")
const BATCH055_REC_ID = UUID("d5500000-0000-4000-8000-000000000001")

function batch055_config(; hub = "false")
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => "postgres://placeholder",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch055.duckdb",
        "SESSION_SECRET" => "batch055-session-secret-placeholder",
        "METRICS_TOKEN" => "batch055-metrics-token-placeholder",
        "PUBLIC_BASE_URL" => "https://ias.example.test",
        "NOTIFICATION_HUB_ENABLED" => hub,
        "NOTIFICATION_HUB_URL" => "https://notify.example.test",
        "NOTIFICATION_HUB_API_KEY" => "placeholder-hub-key",
    ))
end

function batch055_store()
    store = batch012_store()
    store.simulation_runs[BATCH055_RUN_ID] = Dict{Symbol,Any}(
        :id => BATCH055_RUN_ID,
        :tenant_id => BATCH012_TENANT_A,
        :policy_id => UUID("b0000000-0000-4000-8000-000000000001"),
        :name => "Batch 055 failed run",
        :status => "failed",
        :input_snapshot => Dict{String,Any}(),
        :scenario_count => 2,
        :started_at => DateTime(2026, 5, 8, 8),
        :completed_at => DateTime(2026, 5, 8, 8, 10),
        :error_message => "solver timed out",
        :created_by_user_id => BATCH012_PLANNER_A.user_id,
        :created_at => DateTime(2026, 5, 8, 8),
        :updated_at => DateTime(2026, 5, 8, 8, 10),
    )
    store.allocation_recommendations[BATCH055_REC_ID] = Dict{Symbol,Any}(
        :id => BATCH055_REC_ID,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => BATCH055_RUN_ID,
        :from_warehouse_id => UUID("10000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => UUID("10000000-0000-4000-8000-000000000002"),
        :sku_id => UUID("30000000-0000-4000-8000-000000000001"),
        :transfer_units => 9.0,
        :expected_stockout_reduction_units => 7.0,
        :expected_margin_gain_cents => 4400,
        :transfer_cost_cents => 900,
        :net_value_cents => -1,
        :confidence_score => 0.72,
        :explanation => Dict(
            "binding_constraints" => ["safety_stock"],
            "scenario_sensitivity" => Dict("scenario_count" => 2),
            "accepted_tradeoffs" => ["lower confidence"],
            "net_value" => Dict("expected_benefit_cents" => 3800, "expected_margin_gain_cents" => 4400, "transfer_cost_cents" => 900, "holding_cost_cents" => 125, "net_value_cents" => 7175),
        ),
        :status => "proposed",
        :created_at => DateTime(2026, 5, 8, 8, 15),
        :updated_at => DateTime(2026, 5, 8, 8, 15),
    )
    return store
end

@testset "Batch 055 local notifications survive disabled Notification Hub" begin
    store = batch055_store()
    event = build_recommendation_high_value_notification_event(store, BATCH012_PLANNER_A, BATCH055_REC_ID, "evt-batch055-disabled")

    result = create_local_notifications_with_optional_hub_mirror!(store, batch055_config(), event)

    @test result.local_delivery.created_count == 1
    @test result.hub.mirrored == false
    @test result.hub_failed == false
    @test isempty(store.ecosystem_outbox)
    listed = list_notifications(store, BATCH012_PLANNER_A; params = Dict("unread" => "true"))
    @test length(listed.notifications) == 1
    @test listed.notifications[1].event_id == "evt-batch055-disabled"
    @test listed.notifications[1].payload["net_value_cents"] == 7175
end

@testset "Batch 055 local notifications survive Notification Hub enqueue and dispatch failures" begin
    store = batch055_store()
    event = build_recommendation_high_value_notification_event(store, BATCH012_PLANNER_A, BATCH055_REC_ID, "evt-batch055-failing")

    enqueue_result = create_local_notifications_with_optional_hub_mirror!(store, batch055_config(; hub = "true"), event)
    @test enqueue_result.local_delivery.created_count == 1
    @test enqueue_result.hub.mirrored == true
    @test enqueue_result.hub_failed == false
    @test length(store.ecosystem_outbox) == 1
    local_ids_before = sort(collect(keys(store.local_notifications)))

    dispatch_result = dispatch_outbox_once!(store, batch055_config(; hub = "true"); now = DateTime(2030, 5, 8, 9), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 503, body = "hub unavailable"))

    @test dispatch_result.failed == 1
    @test only(values(store.ecosystem_outbox))[:status] == "failed"
    @test sort(collect(keys(store.local_notifications))) == local_ids_before
    listed = list_notifications(store, BATCH012_PLANNER_A; params = Dict("unread" => "true"))
    @test length(listed.notifications) == 1
    @test listed.notifications[1].event_id == "evt-batch055-failing"
    @test listed.notifications[1].read_at === nothing

    duplicate = create_local_notifications_with_optional_hub_mirror!(store, batch055_config(; hub = "true"), event)
    @test duplicate.local_delivery.idempotent == true
    @test length(list_notifications(store, BATCH012_PLANNER_A; params = Dict("unread" => "true")).notifications) == 1
end

@testset "Batch 055 local notification helper records mirror exceptions without dropping local rows" begin
    store = batch055_store()
    event = build_recommendation_high_value_notification_event(store, BATCH012_PLANNER_A, BATCH055_REC_ID, "evt-batch055-mirror-exception")

    result = create_local_notifications_with_optional_hub_mirror!(
        store,
        batch055_config(; hub = "true"),
        event;
        mirror! = (_store, _config, _event) -> error("hub mirror unavailable"),
    )

    @test result.local_delivery.created_count == 1
    @test result.hub_failed == true
    @test occursin("hub mirror unavailable", result.hub_error)
    @test isempty(store.ecosystem_outbox)
    listed = list_notifications(store, BATCH012_PLANNER_A; params = Dict("unread" => "true"))
    @test length(listed.notifications) == 1
    @test listed.notifications[1].event_id == "evt-batch055-mirror-exception"
end
