using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH030_REC_ID = UUID("d3000000-0000-4000-8000-000000000001")
const BATCH030_REC_OTHER_TENANT = UUID("d3000000-0000-4000-8000-000000000002")
const BATCH030_RUN_ID = UUID("e3000000-0000-4000-8000-000000000001")
const BATCH030_SECOND_PLANNER_A = UUID("eeeeeeee-1212-4121-8121-121212121212")

function batch030_recommendation(id, tenant_id = BATCH012_TENANT_A; status = "approved", net_value = 4425)
    return Dict{Symbol,Any}(
        :id => id,
        :tenant_id => tenant_id,
        :simulation_run_id => BATCH030_RUN_ID,
        :from_warehouse_id => UUID("10000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => UUID("10000000-0000-4000-8000-000000000002"),
        :sku_id => UUID("30000000-0000-4000-8000-000000000001"),
        :transfer_units => 14.0,
        :expected_stockout_reduction_units => 11.0,
        :expected_margin_gain_cents => 2500,
        :transfer_cost_cents => 975,
        :net_value_cents => -1,
        :confidence_score => 0.77,
        :explanation => Dict(
            "binding_constraints" => ["lane_capacity"],
            "scenario_sensitivity" => Dict("scenario_count" => 3),
            "accepted_tradeoffs" => ["transfer_cost"],
            "net_value" => Dict("expected_benefit_cents" => 3000, "expected_margin_gain_cents" => 2500, "transfer_cost_cents" => 975, "holding_cost_cents" => 100, "net_value_cents" => net_value),
        ),
        :status => status,
        :created_at => DateTime(2026, 5, 5, 9),
        :updated_at => DateTime(2026, 5, 5, 9),
    )
end

function batch030_store()
    store = batch012_store()
    store.allocation_recommendations[BATCH030_REC_ID] = batch030_recommendation(BATCH030_REC_ID)
    store.allocation_recommendations[BATCH030_REC_OTHER_TENANT] = batch030_recommendation(BATCH030_REC_OTHER_TENANT, BATCH012_TENANT_B; net_value = 9999)
    return store
end

@testset "Batch 030 notification API lists and marks tenant-scoped rows idempotently" begin
    store = batch030_store()
    store.users[BATCH030_SECOND_PLANNER_A] = Dict{Symbol,Any}(
        :id => BATCH030_SECOND_PLANNER_A,
        :tenant_id => BATCH012_TENANT_A,
        :email => "planner-two@northstar.example.test",
        :name => "Northstar Second Planner",
        :role => "planner",
        :is_active => true,
    )
    second_planner_ctx = TenantContext(BATCH012_TENANT_A; user_id = BATCH030_SECOND_PLANNER_A, role = "planner", auth_method = :session)
    event = build_local_notification_event(
        "allocation.high_value_found",
        BATCH012_TENANT_A,
        "evt-batch030-high-value";
        source_record_type = "allocation_recommendation",
        source_record_id = BATCH030_REC_ID,
        title = "High-value allocation found",
        payload = Dict("recommendation_id" => string(BATCH030_REC_ID), "net_value_cents" => 4425),
    )
    created = create_local_notifications!(store, event)
    other_event = build_local_notification_event(
        "allocation.high_value_found",
        BATCH012_TENANT_B,
        "evt-batch030-other";
        source_record_type = "allocation_recommendation",
        source_record_id = BATCH030_REC_OTHER_TENANT,
    )
    create_local_notifications!(store, other_event)

    @test Set(created.recipient_user_ids) == Set([string(BATCH012_PLANNER_A.user_id), string(BATCH030_SECOND_PLANNER_A)])
    @test created.created_count == 2
    @test length(created.notification_ids) == 2

    listed = list_notifications(store, BATCH012_PLANNER_A; params = Dict("limit" => "25"))
    second_listed = list_notifications(store, second_planner_ctx; params = Dict("limit" => "25"))
    @test length(listed.notifications) == 1
    @test length(second_listed.notifications) == 1
    @test listed.notifications[1].event_id == "evt-batch030-high-value"
    @test second_listed.notifications[1].event_id == "evt-batch030-high-value"
    @test listed.notifications[1].tenant_id == string(BATCH012_TENANT_A)
    @test second_listed.notifications[1].tenant_id == string(BATCH012_TENANT_A)
    @test listed.notifications[1].user_id == string(BATCH012_PLANNER_A.user_id)
    @test second_listed.notifications[1].user_id == string(BATCH030_SECOND_PLANNER_A)
    @test listed.notifications[1].read_at === nothing
    @test listed.notifications[1].payload["net_value_cents"] == 4425
    @test listed.notifications[1].payload["recipient_user_ids"] == created.recipient_user_ids
    @test all(row -> row.tenant_id != string(BATCH012_TENANT_B), listed.notifications)

    notification_id = UUID(listed.notifications[1].id)
    first_read = mark_notification_read!(store, BATCH012_PLANNER_A, notification_id)
    second_read = mark_notification_read!(store, BATCH012_PLANNER_A, notification_id)
    @test first_read.idempotent == false
    @test second_read.idempotent == true
    @test first_read.notification.read_at !== nothing
    @test second_read.notification.id == first_read.notification.id
    @test_throws ApiError mark_notification_read!(store, BATCH012_PLANNER_A, first([id for id in keys(store.local_notifications) if store.local_notifications[id][:tenant_id] == BATCH012_TENANT_B]))
end

@testset "Batch 030 optional Notification Hub mirror is feature flagged and idempotent" begin
    store = batch030_store()
    config_disabled = batch012_config()
    event = build_local_notification_event(
        "allocation.high_value_found",
        BATCH012_TENANT_A,
        "evt-batch030-mirror";
        source_record_type = "allocation_recommendation",
        source_record_id = BATCH030_REC_ID,
        payload = Dict("recommendation_id" => string(BATCH030_REC_ID), "net_value_cents" => 4425),
    )
    disabled = mirror_notification_hub_outbox!(store, config_disabled, event)
    @test disabled.mirrored == false
    @test length(store.ecosystem_outbox) == 0

    config_enabled = InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => "postgres://placeholder",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch030.duckdb",
        "SESSION_SECRET" => "batch030-session-secret-placeholder",
        "METRICS_TOKEN" => "batch030-metrics-token-placeholder",
        "NOTIFICATION_HUB_ENABLED" => "true",
        "NOTIFICATION_HUB_URL" => "https://notify.example.test",
        "NOTIFICATION_HUB_API_KEY" => "placeholder",
    ))
    first_mirror = mirror_notification_hub_outbox!(store, config_enabled, event)
    second_mirror = mirror_notification_hub_outbox!(store, config_enabled, event)
    @test first_mirror.mirrored == true
    @test first_mirror.idempotent == false
    @test second_mirror.idempotent == true
    @test length(store.ecosystem_outbox) == 1
    row = first(values(store.ecosystem_outbox))
    @test row[:tenant_id] == BATCH012_TENANT_A
    @test row[:target] == "notification_hub"
    @test row[:status] == "queued"
    @test row[:payload]["event_type"] == "allocation.high_value_found"
    @test row[:payload]["payload"]["net_value_cents"] == 4425
end

@testset "Batch 030 recommendation CSV export and notification payload share canonical net value" begin
    store = batch030_store()
    api_response = get_recommendation(store, BATCH012_PLANNER_A, BATCH030_REC_ID)
    view_model = recommendation_view_model(store.allocation_recommendations[BATCH030_REC_ID])
    csv = export_recommendation_csv(store, BATCH012_PLANNER_A, BATCH030_REC_ID)
    event = build_recommendation_high_value_notification_event(store, BATCH012_PLANNER_A, BATCH030_REC_ID, "evt-batch030-parity")

    @test api_response.net_value_cents == 4425
    @test view_model.net_value_cents == 4425
    @test occursin("net_value_cents", csv.body)
    @test occursin(",4425,", csv.body)
    @test event.payload["net_value_cents"] == 4425
    @test event.payload["net_value"]["holding_cost_cents"] == 100
    @test !occursin("9999", csv.body)
    @test_throws ApiError export_recommendation_csv(store, BATCH012_PLANNER_A, BATCH030_REC_OTHER_TENANT)
end

@testset "Batch 030 SQL local notification contract fans out per recipient" begin
    source = lowercase(replace(read(joinpath(project_root(), "src", "notifications", "local_notifications.jl"), String), r"\s+" => " "))
    migration_sql = lowercase(read(joinpath(project_root(), "migrations", "007_local_notifications_recipient_fanout.up.sql"), String))

    @test occursin("for user_id in target_user_ids", source)
    @test occursin("on conflict (tenant_id, event_id, user_id)", source)
    @test occursin("local_notifications_tenant_event_user_idx", migration_sql)
    @test occursin("nulls not distinct", migration_sql)
end

@testset "Batch 030 routes wire notification and CSV export entrypoints" begin
    defs = route_definitions()
    names = Set(def.name for def in defs)
    @test "notifications_list" in names
    @test "notifications_read" in names
    @test "notifications_page" in names
    @test "recommendations_export_csv" in names
end
