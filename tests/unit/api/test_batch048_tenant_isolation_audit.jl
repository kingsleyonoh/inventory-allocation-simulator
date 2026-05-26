using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH048_REC_A = UUID("d4800000-0000-4000-8000-000000000001")
const BATCH048_REC_B = UUID("d4800000-0000-4000-8000-000000000002")
const BATCH048_RUN_A = UUID("e4800000-0000-4000-8000-000000000001")
const BATCH048_RUN_B = UUID("e4800000-0000-4000-8000-000000000002")

function batch048_recommendation(id::UUID, tenant_id::UUID, run_id::UUID; status = "approved", net_value = 4812, created_at = DateTime(2026, 5, 1, 8))
    return Dict{Symbol,Any}(
        :id => id,
        :tenant_id => tenant_id,
        :simulation_run_id => run_id,
        :from_warehouse_id => tenant_id == BATCH012_TENANT_A ? UUID("10000000-0000-4000-8000-000000000001") : UUID("20000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => tenant_id == BATCH012_TENANT_A ? UUID("10000000-0000-4000-8000-000000000002") : UUID("20000000-0000-4000-8000-000000000001"),
        :sku_id => tenant_id == BATCH012_TENANT_A ? UUID("30000000-0000-4000-8000-000000000001") : UUID("40000000-0000-4000-8000-000000000001"),
        :transfer_units => 12.0,
        :expected_stockout_reduction_units => 10.0,
        :expected_margin_gain_cents => 3000,
        :transfer_cost_cents => 900,
        :net_value_cents => -999999,
        :confidence_score => 0.81,
        :explanation => Dict(
            "binding_constraints" => ["lane_capacity"],
            "scenario_sensitivity" => Dict("scenario_count" => 2),
            "accepted_tradeoffs" => ["transfer_cost"],
            "net_value" => Dict("expected_benefit_cents" => net_value - 3000 + 900 + 100, "expected_margin_gain_cents" => 3000, "transfer_cost_cents" => 900, "holding_cost_cents" => 100, "net_value_cents" => net_value),
        ),
        :status => status,
        :created_at => created_at,
        :updated_at => created_at,
    )
end

function batch048_store_with_recommendations()
    store = batch012_store()
    store.simulation_runs[BATCH048_RUN_A] = Dict{Symbol,Any}(
        :id => BATCH048_RUN_A, :tenant_id => BATCH012_TENANT_A,
        :policy_id => UUID("b0000000-0000-4000-8000-000000000001"), :name => "Northstar isolation run",
        :status => "completed", :input_snapshot => Dict{String,Any}(), :scenario_count => 2,
        :started_at => DateTime(2026, 5, 1, 8), :completed_at => DateTime(2026, 5, 1, 8, 5),
        :error_message => nothing, :created_by_user_id => BATCH012_PLANNER_A.user_id,
        :idempotency_key => nothing, :created_at => DateTime(2026, 5, 1, 8), :updated_at => DateTime(2026, 5, 1, 8),
    )
    store.simulation_runs[BATCH048_RUN_B] = Dict{Symbol,Any}(
        :id => BATCH048_RUN_B, :tenant_id => BATCH012_TENANT_B,
        :policy_id => UUID("c0000000-0000-4000-8000-000000000001"), :name => "Kōwhai isolation run",
        :status => "completed", :input_snapshot => Dict{String,Any}(), :scenario_count => 2,
        :started_at => DateTime(2026, 5, 1, 8), :completed_at => DateTime(2026, 5, 1, 8, 5),
        :error_message => nothing, :created_by_user_id => BATCH012_ADMIN_B.user_id,
        :idempotency_key => nothing, :created_at => DateTime(2026, 5, 1, 8), :updated_at => DateTime(2026, 5, 1, 8),
    )
    store.allocation_recommendations[BATCH048_REC_A] = batch048_recommendation(BATCH048_REC_A, BATCH012_TENANT_A, BATCH048_RUN_A; status = "approved", net_value = 4812)
    store.allocation_recommendations[BATCH048_REC_B] = batch048_recommendation(BATCH048_REC_B, BATCH012_TENANT_B, BATCH048_RUN_B; status = "approved", net_value = 9948)
    return store
end

@testset "Batch 048 API and export paths reject cross-tenant data leakage" begin
    store = batch048_store_with_recommendations()

    warehouses = list_warehouses(store, BATCH012_PLANNER_A; params = Dict("limit" => "25")).warehouses
    skus = list_skus(store, BATCH012_PLANNER_A; params = Dict("limit" => "25")).skus
    inventory = list_inventory_positions(store, BATCH012_PLANNER_A; params = Dict("limit" => "25")).inventory
    recommendations = list_recommendations(store, BATCH012_PLANNER_A; params = Dict("limit" => "25")).recommendations
    csv_export = export_recommendation_csv(store, BATCH012_PLANNER_A, BATCH048_REC_A)

    @test !isempty(warehouses)
    @test !isempty(skus)
    @test !isempty(inventory)
    @test all(row -> row.tenant_id == string(BATCH012_TENANT_A), warehouses)
    @test all(row -> row.tenant_id == string(BATCH012_TENANT_A), skus)
    @test all(row -> row.tenant_id == string(BATCH012_TENANT_A), inventory)
    @test all(row -> row.tenant_id == string(BATCH012_TENANT_A), recommendations)
    @test !occursin("Wellington", csv_export.body)
    @test !occursin("SKU-KIWI", csv_export.body)
    @test !occursin("9948", csv_export.body)
    @test occursin("4812", csv_export.body)
    @test_throws ApiError get_recommendation(store, BATCH012_PLANNER_A, BATCH048_REC_B)
    @test_throws ApiError export_recommendation_csv(store, BATCH012_PLANNER_A, BATCH048_REC_B)
end

@testset "Batch 048 UI and job paths isolate tenant-scoped state" begin
    store = batch048_store_with_recommendations()
    html = render_dashboard_page(store, BATCH012_VIEWER_A) * render_warehouses_page(store, BATCH012_PLANNER_A) * render_recommendation_detail_page(store, BATCH012_PLANNER_A, string(BATCH048_REC_A))

    @test occursin("Bristol", html)
    @test occursin("4812", html)
    @test !occursin("Kōwhai", html)
    @test !occursin("Wellington", html)
    @test !occursin("9948", html)
    @test_throws ApiError render_recommendation_detail_page(store, BATCH012_PLANNER_A, string(BATCH048_REC_B))

    store.allocation_recommendations[BATCH048_REC_A][:status] = "proposed"
    store.allocation_recommendations[BATCH048_REC_A][:created_at] = DateTime(2026, 4, 1, 8)
    store.allocation_recommendations[BATCH048_REC_B][:status] = "proposed"
    store.allocation_recommendations[BATCH048_REC_B][:created_at] = DateTime(2026, 4, 1, 8)
    result = expire_due_recommendations!(store; now = DateTime(2026, 5, 20, 9), default_expiry_days = 7)

    @test Set(result.expired_recommendation_ids) == Set(string.([BATCH048_REC_A, BATCH048_REC_B]))
    @test store.allocation_recommendations[BATCH048_REC_A][:status] == "expired"
    @test store.allocation_recommendations[BATCH048_REC_B][:status] == "expired"
    decisions_a = [row for row in values(store.recommendation_decisions) if row[:recommendation_id] == BATCH048_REC_A]
    decisions_b = [row for row in values(store.recommendation_decisions) if row[:recommendation_id] == BATCH048_REC_B]
    @test !isempty(decisions_a)
    @test !isempty(decisions_b)
    @test all(row -> row[:tenant_id] == BATCH012_TENANT_A, decisions_a)
    @test all(row -> row[:tenant_id] == BATCH012_TENANT_B, decisions_b)
end

@testset "Batch 048 tenant isolation audit gate is rerunnable" begin
    script = joinpath(project_root(), ".yolo", "scripts", "validate-batch-048-tenant-isolation.sh")
    @test isfile(script)
    isfile(script) || return
    source = read(script, String)
    for token in ["list_warehouses", "render_dashboard_page", "expire_due_recommendations!", "export_recommendation_csv", "TENANT_ISOLATION_AUDIT"]
        @test occursin(token, source)
    end
end
