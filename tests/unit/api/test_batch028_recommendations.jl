using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH028_REC_ID = UUID("d2800000-0000-4000-8000-000000000001")

function batch028_store_with_recommendation(; status = "proposed", created_at = DateTime(2026, 5, 20, 9))
    store = batch012_store()
    store.allocation_recommendations[BATCH028_REC_ID] = Dict{Symbol,Any}(
        :id => BATCH028_REC_ID,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => UUID("e2800000-0000-4000-8000-000000000001"),
        :from_warehouse_id => UUID("10000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => UUID("10000000-0000-4000-8000-000000000002"),
        :sku_id => UUID("30000000-0000-4000-8000-000000000001"),
        :transfer_units => 10.0,
        :expected_stockout_reduction_units => 12.0,
        :expected_margin_gain_cents => 6000,
        :transfer_cost_cents => 1250,
        :net_value_cents => 4750,
        :confidence_score => 0.81,
        :explanation => Dict(
            "binding_constraints" => ["lane capacity"],
            "scenario_sensitivity" => Dict("scenario_count" => 2),
            "accepted_tradeoffs" => ["cost accepted for service"],
        ),
        :status => status,
        :created_at => created_at,
        :updated_at => created_at,
    )
    return store
end

@testset "Batch 028 operations console accessibility and responsive checks" begin
    store = batch028_store_with_recommendation()
    html = render_recommendation_detail_page(store, BATCH012_PLANNER_A, string(BATCH028_REC_ID))
    shell = InventoryAllocationSimulator._app_shell("Accessibility", "<section class=\"ias-table-wrap\"><table><caption>Semantic check</caption><thead><tr><th scope=\"col\">A</th></tr></thead><tbody><tr><td>B</td></tr></tbody></table></section>")

    @test occursin("<meta name=\"viewport\"", html)
    @test occursin("@media (max-width: 800px)", html)
    @test occursin("@media (prefers-reduced-motion: reduce)", html)
    @test occursin("focus-visible", html)
    @test occursin("outline: 3px solid var(--focus)", html)
    @test occursin("caption", shell)
    @test occursin("scope=\"col\"", shell)
    @test occursin("aria-label=\"Recommendation actions\"", html)
    @test occursin("method=\"post\" action=\"/api/recommendations/$(BATCH028_REC_ID)/approve\"", html)
    @test occursin("method=\"post\" action=\"/api/recommendations/$(BATCH028_REC_ID)/reject\"", html)
    @test occursin("method=\"post\" action=\"/api/recommendations/$(BATCH028_REC_ID)/export\"", html)
    @test !occursin("disabled until recommendation transition endpoints", html)
    @test occursin("--ink:#122033", html)
    @test occursin("--bg:#f7f9fc", html)
    @test occursin("Skip to content", html)
end

@testset "Batch 028 recommendation transition routes are registered" begin
    routes = Set((def.method, def.path) for def in route_definitions())
    expected = Set([
        (:GET, "/api/recommendations"),
        (:GET, "/api/recommendations/:id"),
        (:POST, "/api/recommendations/:id/approve"),
        (:POST, "/api/recommendations/:id/reject"),
        (:POST, "/api/recommendations/:id/expire"),
        (:POST, "/api/recommendations/:id/export"),
    ])
    @test issubset(expected, routes)
end

@testset "Batch 028 approve transition writes one decision row and is idempotent" begin
    store = batch028_store_with_recommendation()
    result = approve_recommendation!(store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => "planner accepted service tradeoff"))
    @test result.recommendation.status == "approved"
    @test result.decision.decision == "approved"
    @test result.decision.reason == "planner accepted service tradeoff"
    @test length(store.recommendation_decisions) == 1
    @test store.allocation_recommendations[BATCH028_REC_ID][:status] == "approved"

    again = approve_recommendation!(store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => "planner accepted service tradeoff"))
    @test again.idempotent == true
    @test again.decision.id == result.decision.id
    @test length(store.recommendation_decisions) == 1

    @test_throws ApiError approve_recommendation!(store, BATCH012_ADMIN_A, BATCH028_REC_ID, Dict("reason" => "different body"))
    @test_throws AuthzError approve_recommendation!(store, BATCH012_VIEWER_A, BATCH028_REC_ID, Dict())
end

@testset "Batch 028 reject requires reason and writes audit row" begin
    store = batch028_store_with_recommendation()
    @test_throws ApiError reject_recommendation!(store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => ""))

    result = reject_recommendation!(store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => "lane disruption risk"))
    @test result.recommendation.status == "rejected"
    @test result.decision.decision == "rejected"
    @test result.decision.reason == "lane disruption risk"
    @test length(store.recommendation_decisions) == 1

    @test_throws ApiError export_recommendation!(store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => "cannot export rejected"))
end

@testset "Batch 028 expire uses stored status and policy expiry window" begin
    store = batch028_store_with_recommendation(created_at = DateTime(2026, 5, 1, 9))
    result = expire_recommendation!(store, BATCH012_ADMIN_A, BATCH028_REC_ID, Dict("reason" => "hourly expiry"); now = () -> DateTime(2026, 5, 10, 9), expiry_days = 7)
    @test result.recommendation.status == "expired"
    @test result.decision.decision == "expired"
    @test result.decision.reason == "hourly expiry"

    fresh_store = batch028_store_with_recommendation(created_at = DateTime(2026, 5, 9, 9))
    @test_throws ApiError expire_recommendation!(fresh_store, BATCH012_ADMIN_A, BATCH028_REC_ID, Dict(); now = () -> DateTime(2026, 5, 10, 9), expiry_days = 7)

    approved_store = batch028_store_with_recommendation(status = "approved", created_at = DateTime(2026, 5, 1, 9))
    @test_throws ApiError expire_recommendation!(approved_store, BATCH012_ADMIN_A, BATCH028_REC_ID, Dict(); now = () -> DateTime(2026, 5, 10, 9), expiry_days = 7)
end

@testset "Batch 028 export eligibility requires approved recommendation and records decision" begin
    store = batch028_store_with_recommendation(status = "approved")
    result = export_recommendation!(store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => "download CSV transfer plan"))
    @test result.recommendation.status == "exported"
    @test result.decision.decision == "exported"
    @test result.export_eligible == true
    @test length(store.recommendation_decisions) == 1

    proposed_store = batch028_store_with_recommendation()
    @test_throws ApiError export_recommendation!(proposed_store, BATCH012_PLANNER_A, BATCH028_REC_ID, Dict("reason" => "too soon"))
end

@testset "Batch 028 SQL transitions are atomic and NULL-user idempotent" begin
    source = read(joinpath(project_root(), "src", "recommendations", "decisions.jl"), String)
    normalized = lowercase(replace(source, r"\s+" => " "))

    @test occursin("is not distinct from", normalized)
    @test occursin("function _persist_recommendation_transition!(store::sqltenantadminstore", normalized)
    @test occursin("begin", normalized)
    @test occursin("commit", normalized)
    @test occursin("rollback", normalized)
    @test occursin("updated = _persist_recommendation_transition!(store, recommendation, decision_row, next_status)", normalized)
end
