using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH052_REC_A = UUID("d5200000-0000-4000-8000-000000000001")
const BATCH052_REC_B = UUID("d5200000-0000-4000-8000-000000000002")
const BATCH052_RUN_A = UUID("e5200000-0000-4000-8000-000000000001")
const BATCH052_RUN_B = UUID("e5200000-0000-4000-8000-000000000002")

function batch052_recommendation(id::UUID, tenant_id::UUID, run_id::UUID; canonical_net_value = 7654, stale_row_net_value = -123456)
    return Dict{Symbol,Any}(
        :id => id,
        :tenant_id => tenant_id,
        :simulation_run_id => run_id,
        :from_warehouse_id => tenant_id == BATCH012_TENANT_A ? UUID("10000000-0000-4000-8000-000000000001") : UUID("20000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => tenant_id == BATCH012_TENANT_A ? UUID("10000000-0000-4000-8000-000000000002") : UUID("20000000-0000-4000-8000-000000000001"),
        :sku_id => tenant_id == BATCH012_TENANT_A ? UUID("30000000-0000-4000-8000-000000000001") : UUID("40000000-0000-4000-8000-000000000001"),
        :transfer_units => 18.0,
        :expected_stockout_reduction_units => 16.0,
        :expected_margin_gain_cents => 2500,
        :transfer_cost_cents => 900,
        :net_value_cents => stale_row_net_value,
        :confidence_score => 0.88,
        :explanation => Dict(
            "binding_constraints" => ["lane_capacity"],
            "scenario_sensitivity" => Dict("scenario_count" => 4),
            "accepted_tradeoffs" => ["transfer_cost"],
            "net_value" => Dict(
                "expected_benefit_cents" => canonical_net_value - 2500 + 900 + 200,
                "expected_margin_gain_cents" => 2500,
                "transfer_cost_cents" => 900,
                "holding_cost_cents" => 200,
                "net_value_cents" => canonical_net_value,
            ),
        ),
        :status => "approved",
        :created_at => DateTime(2026, 5, 20, 8),
        :updated_at => DateTime(2026, 5, 20, 8),
    )
end

function batch052_store_with_recommendations()
    store = batch012_store()
    store.simulation_runs[BATCH052_RUN_A] = Dict{Symbol,Any}(
        :id => BATCH052_RUN_A, :tenant_id => BATCH012_TENANT_A,
        :policy_id => UUID("b0000000-0000-4000-8000-000000000001"), :name => "Northstar net value parity run",
        :status => "completed", :input_snapshot => Dict{String,Any}(), :scenario_count => 4,
        :started_at => DateTime(2026, 5, 20, 8), :completed_at => DateTime(2026, 5, 20, 8, 5),
        :error_message => nothing, :created_by_user_id => BATCH012_PLANNER_A.user_id,
        :idempotency_key => nothing, :created_at => DateTime(2026, 5, 20, 8), :updated_at => DateTime(2026, 5, 20, 8),
    )
    store.simulation_runs[BATCH052_RUN_B] = Dict{Symbol,Any}(
        :id => BATCH052_RUN_B, :tenant_id => BATCH012_TENANT_B,
        :policy_id => UUID("c0000000-0000-4000-8000-000000000001"), :name => "Kōwhai net value parity run",
        :status => "completed", :input_snapshot => Dict{String,Any}(), :scenario_count => 4,
        :started_at => DateTime(2026, 5, 20, 8), :completed_at => DateTime(2026, 5, 20, 8, 5),
        :error_message => nothing, :created_by_user_id => BATCH012_ADMIN_B.user_id,
        :idempotency_key => nothing, :created_at => DateTime(2026, 5, 20, 8), :updated_at => DateTime(2026, 5, 20, 8),
    )
    store.allocation_recommendations[BATCH052_REC_A] = batch052_recommendation(BATCH052_REC_A, BATCH012_TENANT_A, BATCH052_RUN_A; canonical_net_value = 7654, stale_row_net_value = -123456)
    store.allocation_recommendations[BATCH052_REC_B] = batch052_recommendation(BATCH052_REC_B, BATCH012_TENANT_B, BATCH052_RUN_B; canonical_net_value = 8888, stale_row_net_value = -888888)
    return store
end

@testset "Batch 052 net value parity audit covers API UI CSV and notification payload" begin
    store = batch052_store_with_recommendations()

    api_response = get_recommendation(store, BATCH012_PLANNER_A, BATCH052_REC_A)
    html = render_recommendation_detail_page(store, BATCH012_PLANNER_A, string(BATCH052_REC_A))
    csv = export_recommendation_csv(store, BATCH012_PLANNER_A, BATCH052_REC_A)
    event = build_recommendation_high_value_notification_event(store, BATCH012_PLANNER_A, BATCH052_REC_A, "evt-batch052-parity")

    @test api_response.net_value_cents == 7654
    @test api_response.net_value.net_value_cents == 7654
    @test occursin("7654¢", html)
    @test occursin(",7654,", csv.body)
    @test csv.net_value_cents == 7654
    @test event.payload["net_value_cents"] == 7654
    @test event.payload["net_value"]["net_value_cents"] == 7654
    @test !occursin("-123456", html)
    @test !occursin("-123456", csv.body)
    @test event.payload["net_value_cents"] != store.allocation_recommendations[BATCH052_REC_A][:net_value_cents]
end

@testset "Batch 052 net value parity audit rejects cross-tenant and missing recommendations" begin
    store = batch052_store_with_recommendations()

    @test_throws ApiError get_recommendation(store, BATCH012_PLANNER_A, BATCH052_REC_B)
    @test_throws ApiError render_recommendation_detail_page(store, BATCH012_PLANNER_A, string(BATCH052_REC_B))
    @test_throws ApiError export_recommendation_csv(store, BATCH012_PLANNER_A, BATCH052_REC_B)
    @test_throws ApiError build_recommendation_high_value_notification_event(store, BATCH012_PLANNER_A, BATCH052_REC_B, "evt-batch052-cross-tenant")
    @test_throws ApiError get_recommendation(store, BATCH012_PLANNER_A, UUID("d5200000-0000-4000-8000-000000000099"))
end

@testset "Batch 052 net value parity audit gate is rerunnable" begin
    script = joinpath(project_root(), ".yolo", "scripts", "validate-batch-052-net-value-parity.sh")
    @test isfile(script)
    isfile(script) || return
    source = read(script, String)
    for token in ["NET_VALUE_PARITY_AUDIT", "get_recommendation", "render_recommendation_detail_page", "export_recommendation_csv", "build_recommendation_high_value_notification_event", "_canonical_recommendation_net_value"]
        @test occursin(token, source)
    end
end
