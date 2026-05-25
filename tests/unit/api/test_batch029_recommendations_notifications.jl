using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH029_REC_EXPIRED = UUID("d2900000-0000-4000-8000-000000000001")
const BATCH029_REC_FRESH = UUID("d2900000-0000-4000-8000-000000000002")
const BATCH029_REC_APPROVED = UUID("d2900000-0000-4000-8000-000000000003")
const BATCH029_RUN_ID = UUID("e2900000-0000-4000-8000-000000000001")
const BATCH029_SOURCE_ID = UUID("f2900000-0000-4000-8000-000000000001")

function batch029_recommendation(id; status = "proposed", created_at = DateTime(2026, 5, 1, 9))
    return Dict{Symbol,Any}(
        :id => id,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => BATCH029_RUN_ID,
        :from_warehouse_id => UUID("10000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => UUID("10000000-0000-4000-8000-000000000002"),
        :sku_id => UUID("30000000-0000-4000-8000-000000000001"),
        :transfer_units => 10.0,
        :expected_stockout_reduction_units => 12.0,
        :expected_margin_gain_cents => 6000,
        :transfer_cost_cents => 1250,
        :net_value_cents => 4750,
        :confidence_score => 0.81,
        :explanation => Dict("binding_constraints" => ["lane capacity"], "scenario_sensitivity" => Dict("scenario_count" => 2), "accepted_tradeoffs" => ["service tradeoff"]),
        :status => status,
        :created_at => created_at,
        :updated_at => created_at,
    )
end

function batch029_store_with_recommendations()
    store = batch012_store()
    store.simulation_runs[BATCH029_RUN_ID] = Dict{Symbol,Any}(
        :id => BATCH029_RUN_ID,
        :tenant_id => BATCH012_TENANT_A,
        :policy_id => UUID("b0000000-0000-4000-8000-000000000001"),
        :name => "Batch 029 run",
        :status => "completed",
        :input_snapshot => Dict{String,Any}(),
        :scenario_count => 1,
        :started_at => DateTime(2026, 5, 1, 8),
        :completed_at => DateTime(2026, 5, 1, 9),
        :created_by_user_id => BATCH012_PLANNER_A.user_id,
        :created_at => DateTime(2026, 5, 1, 8),
        :updated_at => DateTime(2026, 5, 1, 9),
    )
    store.allocation_policies[UUID("b0000000-0000-4000-8000-000000000001")][:config] = Dict("recommendation_expiry_days" => 3)
    store.allocation_recommendations[BATCH029_REC_EXPIRED] = batch029_recommendation(BATCH029_REC_EXPIRED; created_at = DateTime(2026, 5, 1, 9))
    store.allocation_recommendations[BATCH029_REC_FRESH] = batch029_recommendation(BATCH029_REC_FRESH; created_at = DateTime(2026, 5, 4, 9))
    store.allocation_recommendations[BATCH029_REC_APPROVED] = batch029_recommendation(BATCH029_REC_APPROVED; status = "approved", created_at = DateTime(2026, 5, 1, 9))
    return store
end

@testset "Batch 029 hourly recommendation expiry job uses status and policy expiry" begin
    store = batch029_store_with_recommendations()
    result = expire_due_recommendations!(store; now = DateTime(2026, 5, 5, 9))

    @test result.expired_count == 1
    @test result.checked_count == 3
    @test result.expired_recommendation_ids == [string(BATCH029_REC_EXPIRED)]
    @test store.allocation_recommendations[BATCH029_REC_EXPIRED][:status] == "expired"
    @test store.allocation_recommendations[BATCH029_REC_FRESH][:status] == "proposed"
    @test store.allocation_recommendations[BATCH029_REC_APPROVED][:status] == "approved"
    @test count(row -> row[:decision] == "expired", values(store.recommendation_decisions)) == 1

    again = expire_due_recommendations!(store; now = DateTime(2026, 5, 6, 9))
    @test again.expired_count == 0
    @test count(row -> row[:decision] == "expired", values(store.recommendation_decisions)) == 1
end

@testset "Batch 029 recommendation transition correctness matrix" begin
    store = batch029_store_with_recommendations()
    approve_result = approve_recommendation!(store, BATCH012_PLANNER_A, BATCH029_REC_FRESH, Dict("reason" => "approve service gain"))
    @test approve_result.recommendation.status == "approved"
    duplicate = approve_recommendation!(store, BATCH012_PLANNER_A, BATCH029_REC_FRESH, Dict("reason" => "approve service gain"))
    @test duplicate.idempotent == true
    @test duplicate.decision.id == approve_result.decision.id
    @test_throws ApiError approve_recommendation!(store, BATCH012_ADMIN_A, BATCH029_REC_FRESH, Dict("reason" => "different duplicate body"))
    export_result = export_recommendation!(store, BATCH012_PLANNER_A, BATCH029_REC_FRESH, Dict("reason" => "export approved transfer"))
    @test export_result.recommendation.status == "exported"
    @test export_result.export_eligible == true

    rejected_id = UUID("d2900000-0000-4000-8000-000000000004")
    store.allocation_recommendations[rejected_id] = batch029_recommendation(rejected_id; created_at = DateTime(2026, 5, 1, 9))
    reject_result = reject_recommendation!(store, BATCH012_ADMIN_A, rejected_id, Dict("reason" => "manual risk review"))
    @test reject_result.recommendation.status == "rejected"
    @test_throws ApiError export_recommendation!(store, BATCH012_ADMIN_A, rejected_id, Dict("reason" => "not exportable"))

    expired_id = UUID("d2900000-0000-4000-8000-000000000005")
    store.allocation_recommendations[expired_id] = batch029_recommendation(expired_id; created_at = DateTime(2026, 5, 1, 9))
    expire_result = expire_recommendation!(store, BATCH012_ADMIN_A, expired_id, Dict("reason" => "policy expiry"); now = () -> DateTime(2026, 5, 6, 9), expiry_days = 3)
    @test expire_result.recommendation.status == "expired"
    @test_throws AuthzError approve_recommendation!(store, BATCH012_VIEWER_A, UUID("d2900000-0000-4000-8000-000000000006"), Dict())
end

@testset "Batch 029 notification inventory validates event and template keys" begin
    spec = notification_event_spec("simulation.failed")
    @test spec.template_key == "simulation_failed"
    @test spec.urgency == "High"
    @test notification_severity(spec) == "critical"
    @test validate_notification_event!("simulation.failed", "simulation_failed") === spec
    @test_throws ApiError validate_notification_event!("simulation.failed", "wrong_template")
    @test_throws ApiError validate_notification_event!("unknown.event", "unknown")
end

@testset "Batch 029 notification recipient resolution honors tenant role urgency and opt-out" begin
    store = batch012_store()
    store.users[BATCH012_PLANNER_A.user_id][:notification_opt_outs] = Dict("medium_email" => true)
    medium_email = resolve_notification_recipients(store, BATCH012_TENANT_A, "simulation.completed"; channel = :email)
    @test string(BATCH012_ADMIN_A.user_id) in medium_email.user_ids
    @test !(string(BATCH012_PLANNER_A.user_id) in medium_email.user_ids)
    @test medium_email.tenant_level == false

    high_email = resolve_notification_recipients(store, BATCH012_TENANT_A, "simulation.failed"; channel = :email, actor_user_id = BATCH012_PLANNER_A.user_id)
    @test high_email.user_ids == [string(BATCH012_PLANNER_A.user_id)]

    admins = resolve_notification_recipients(store, BATCH012_TENANT_B, "recommendation.approved"; channel = :in_app)
    @test admins.user_ids == [string(BATCH012_ADMIN_B.user_id)]
    @test all(id -> id != string(BATCH012_ADMIN_A.user_id), admins.user_ids)
end

@testset "Batch 029 local notification creation is idempotent for standalone in-app delivery" begin
    store = batch012_store()
    event = build_local_notification_event(
        "recommendation.approved",
        BATCH012_TENANT_A,
        "evt-rec-approved-029";
        source_record_type = "allocation_recommendation",
        source_record_id = BATCH029_SOURCE_ID,
        payload = Dict("recommendation_id" => string(BATCH029_SOURCE_ID), "net_value_cents" => 4750),
    )
    first_result = create_local_notifications!(store, event)
    second_result = create_local_notifications!(store, event)

    @test first_result.created_count == 2
    @test first_result.idempotent == false
    @test second_result.created_count == 0
    @test second_result.idempotent == true
    @test length(store.local_notifications) == 2
    @test all(row -> row[:tenant_id] == BATCH012_TENANT_A, values(store.local_notifications))
    @test all(row -> row[:event_id] == "evt-rec-approved-029", values(store.local_notifications))
    @test Set(row[:severity] for row in values(store.local_notifications)) == Set(["warning"])
end

@testset "Batch 029 notification SQL contract preserves tenant idempotency" begin
    source = read(joinpath(project_root(), "src", "notifications", "local_notifications.jl"), String)
    normalized = lowercase(replace(source, r"\s+" => " "))
    @test occursin("on conflict (tenant_id, event_id, user_id)", normalized) || occursin("on conflict on constraint", normalized) || occursin(raw"where tenant_id = \$1", normalized)
    @test occursin(raw"tenant_id = \$1", normalized)
    @test occursin("notification_inventory", normalized)
    @test occursin("notification_opt_outs", normalized)
end

@testset "Batch 029 notification SQL contract enforces persisted opt-outs" begin
    source = read(joinpath(project_root(), "src", "notifications", "local_notifications.jl"), String)
    normalized = lowercase(replace(source, r"\s+" => " "))
    migration_sql = lowercase(read(joinpath(project_root(), "migrations", "006_notification_preferences_and_expiry_policy.up.sql"), String))

    @test occursin("notification_opt_outs jsonb", migration_sql)
    @test occursin("select id, role, notification_opt_outs", normalized)
    @test occursin("_user_opted_out(row, spec, channel)", normalized)
end

@testset "Batch 029 expiry SQL contract validates positive policy expiry" begin
    source = read(joinpath(project_root(), "src", "recommendations", "expiry_jobs.jl"), String)
    normalized = lowercase(replace(source, r"\s+" => " "))
    migration_sql = lowercase(read(joinpath(project_root(), "migrations", "006_notification_preferences_and_expiry_policy.up.sql"), String))

    @test occursin("recommendation_expiry_days", migration_sql)
    @test occursin("check", migration_sql)
    @test occursin("expiry_days > 0", normalized)
end
