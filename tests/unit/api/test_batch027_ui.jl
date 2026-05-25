using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

function batch027_store_with_completed_run_and_recommendation()
    store = batch012_store()
    run = create_simulation_run!(store, BATCH012_PLANNER_A, Dict(
        "policy_id" => "b0000000-0000-4000-8000-000000000001",
        "name" => "Batch 027 detail run",
        "scenario_count" => 2,
    ))
    completed = simulation_worker!(store, BATCH012_ADMIN_A; worker_id = "worker-027", seed = 27027)
    rec_id = UUID("d2700000-0000-4000-8000-000000000001")
    store.allocation_recommendations[rec_id] = Dict{Symbol,Any}(
        :id => rec_id,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => UUID(completed.id),
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
            "scenario_sensitivity" => Dict("scenario_count" => 2, "worst_case_units" => 8),
            "accepted_tradeoffs" => ["higher transfer cost accepted for service level"],
        ),
        :status => "proposed",
        :created_at => DateTime(2026, 5, 25, 9),
    )
    return store, completed
end

@testset "Batch 027 UI routes are registered for operations console pages" begin
    routes = Set((def.method, def.path) for def in route_definitions())
    expected = Set([
        (:GET, "/lanes"), (:POST, "/lanes"), (:POST, "/lanes/:id"),
        (:GET, "/policies"), (:POST, "/policies"), (:POST, "/policies/:id"),
        (:GET, "/settings"), (:POST, "/settings"), (:POST, "/settings/users"), (:POST, "/settings/users/:id"), (:POST, "/settings/api-key/rotate"),
        (:GET, "/simulations"), (:POST, "/simulations"), (:GET, "/simulations/:id"), (:POST, "/simulations/:id/cancel"),
        (:GET, "/recommendations/:id"),
    ])
    @test issubset(expected, routes)

    shell = InventoryAllocationSimulator._app_shell("Route inventory", "<h1>Routes</h1>"; active = "Lanes")
    for href in ["/lanes", "/policies", "/settings", "/simulations"]
        @test occursin("href=\"$href\"", shell)
    end
end

@testset "Batch 027 transfer lane management renders controls and tenant-scoped rows" begin
    store = batch012_store()
    html = render_transfer_lanes_page(store, BATCH012_PLANNER_A)
    @test occursin("Transfer lane management", html)
    @test occursin("name=\"lead_time_days\"", html)
    @test occursin("name=\"cost_per_unit_cents\"", html)
    @test occursin("name=\"capacity_units_day\"", html)
    @test occursin("name=\"active\"", html)
    @test occursin("BRI · Bristol DC → EDI · Edinburgh DC", html)
    @test occursin("2 days", html)
    @test occursin("125¢", html)
    @test occursin("200.0 units/day", html)
    @test occursin("action=\"/lanes/90000000-0000-4000-8000-000000000001\"", html)
    @test occursin("Update lane", html)
    @test occursin("Deactivate lane", html)
    @test !occursin("WLG → WLG", html)

    updated = InventoryAllocationSimulator._apply_lane_ui_form!(store, BATCH012_PLANNER_A, Dict(
        "lead_time_days" => "4", "cost_per_unit_cents" => "155", "capacity_units_day" => "125", "active" => "true",
    ); lane_id = "90000000-0000-4000-8000-000000000001")
    @test updated.lead_time_days == 4
    @test updated.cost_per_unit_cents == 155
    @test updated.capacity_units_day == 125.0
    deactivated = InventoryAllocationSimulator._apply_lane_ui_form!(store, BATCH012_PLANNER_A, Dict("active" => "false"); lane_id = "90000000-0000-4000-8000-000000000001")
    @test deactivated.active == false

    extra = create_warehouse!(store, BATCH012_PLANNER_A, Dict(
        "code" => "man", "name" => "Manchester DC", "region" => "GB-MAN", "capacity_units" => "500",
    ))
    created = InventoryAllocationSimulator._apply_lane_ui_form!(store, BATCH012_PLANNER_A, Dict(
        "from_warehouse_id" => extra.id,
        "to_warehouse_id" => "10000000-0000-4000-8000-000000000001",
        "lead_time_days" => "5",
        "cost_per_unit_cents" => "175",
        "capacity_units_day" => "75",
        "active" => "true",
    ))
    @test created.lead_time_days == 5
    @test created.cost_per_unit_cents == 175
    @test created.capacity_units_day == 75.0
    @test_throws AuthzError InventoryAllocationSimulator._apply_lane_ui_form!(store, BATCH012_VIEWER_A, Dict())

    viewer_html = render_transfer_lanes_page(store, BATCH012_VIEWER_A)
    @test occursin("Permission required to change transfer lanes", viewer_html)
    @test occursin("disabled", viewer_html)
end

@testset "Batch 027 allocation policy view renders objective horizon service and constraint controls" begin
    store = batch012_store()
    html = render_allocation_policies_page(store, BATCH012_ADMIN_A)
    @test occursin("Allocation policy", html)
    @test occursin("name=\"objective\"", html)
    @test occursin("minimize_stockout_cost", html)
    @test occursin("name=\"planning_horizon_days\"", html)
    @test occursin("name=\"service_level_target\"", html)
    @test occursin("name=\"max_transfer_cost_cents\"", html)
    @test occursin("name=\"allow_cross_region\"", html)
    @test occursin("Balanced baseline", html)
    @test occursin("0.95", html)
    @test occursin("action=\"/policies/b0000000-0000-4000-8000-000000000001\"", html)
    @test occursin("Update policy", html)
    @test occursin("Archive policy", html)
    @test !occursin("Kōwhai active", html)

    updated = InventoryAllocationSimulator._apply_policy_ui_form!(store, BATCH012_ADMIN_A, Dict(
        "name" => "Balanced tuned", "objective" => "balanced", "planning_horizon_days" => "45",
        "service_level_target" => "0.96", "max_transfer_cost_cents" => "45000", "allow_cross_region" => "true", "status" => "active",
    ); policy_id = "b0000000-0000-4000-8000-000000000001")
    @test updated.name == "Balanced tuned"
    @test updated.planning_horizon_days == 45
    archived = InventoryAllocationSimulator._apply_policy_ui_form!(store, BATCH012_ADMIN_A, Dict("status" => "archived"); policy_id = "b0000000-0000-4000-8000-000000000001")
    @test archived.status == "archived"

    created = InventoryAllocationSimulator._apply_policy_ui_form!(store, BATCH012_ADMIN_A, Dict(
        "name" => "Service guardrail", "objective" => "minimize_stockout_cost",
        "planning_horizon_days" => "14", "service_level_target" => "0.97",
        "max_transfer_cost_cents" => "12000", "allow_cross_region" => "false", "status" => "active",
    ))
    @test created.name == "Service guardrail"
    @test created.objective == "minimize_stockout_cost"
    @test created.service_level_target == 0.97
    @test created.allow_cross_region == false
    @test_throws AuthzError InventoryAllocationSimulator._apply_policy_ui_form!(store, BATCH012_VIEWER_A, Dict())
end

@testset "Batch 027 tenant settings page renders profile users and API-key management without leaking raw keys" begin
    store = batch012_store()
    config = batch012_config()
    html = render_tenant_settings_page(store, config, BATCH012_ADMIN_A)
    @test occursin("Tenant settings", html)
    @test occursin("Northstar Supply", html)
    @test occursin("name=\"legal_name\"", html)
    @test occursin("admin@northstar.example.test", html)
    @test occursin("planner@northstar.example.test", html)
    @test occursin("Rotate API key", html)
    @test !occursin("ias_test_northstar", html)
    @test !occursin("Kōwhai", html)

    updated = InventoryAllocationSimulator._apply_tenant_settings_ui_form!(store, BATCH012_ADMIN_A, Dict(
        "name" => "Northstar Updated", "legal_name" => "Northstar Updated Ltd",
        "full_legal_name" => "Northstar Updated Limited", "display_name" => "Northstar Updated",
        "contact_email" => "ops-updated@example.test",
    ))
    @test updated.name == "Northstar Updated"
    @test updated.contact["email"] == "ops-updated@example.test"

    new_user = InventoryAllocationSimulator._apply_user_create_ui_form!(store, BATCH012_ADMIN_A, Dict(
        "email" => "viewer2@northstar.example.test", "name" => "Second Viewer", "role" => "viewer", "is_active" => "true",
    ))
    @test new_user.role == "viewer"
    @test_throws AuthzError render_tenant_settings_page(store, config, BATCH012_VIEWER_A)
end

@testset "Batch 027 simulation list and detail render frozen scenario summaries and solver diagnostics" begin
    store, completed = batch027_store_with_completed_run_and_recommendation()
    list_html = render_simulations_page(store, BATCH012_PLANNER_A)
    @test occursin("Simulation runs", list_html)
    @test occursin("Batch 027 detail run", list_html)
    @test occursin("completed", list_html)
    @test occursin("View diagnostics", list_html)

    detail_html = render_simulation_detail_page(store, BATCH012_VIEWER_A, completed.id)
    @test occursin("Scenario summaries", detail_html)
    @test occursin("Solver diagnostics", detail_html)
    @test occursin("binding constraints", lowercase(detail_html))
    @test occursin("scenario sensitivity", lowercase(detail_html))
    @test occursin("Balanced baseline", detail_html)
    @test !occursin("Kōwhai", detail_html)

    @test_throws ApiError render_simulation_detail_page(store, BATCH012_ADMIN_B, completed.id)
end

@testset "Batch 027 recommendation detail renders constraints sensitivity net value and gated actions" begin
    store, completed = batch027_store_with_completed_run_and_recommendation()
    rec = only([row for row in values(store.allocation_recommendations) if row[:simulation_run_id] == UUID(completed.id)])
    html = render_recommendation_detail_page(store, BATCH012_PLANNER_A, string(rec[:id]))
    @test occursin("Recommendation detail", html)
    @test occursin("Net value", html)
    @test occursin(string(rec[:net_value_cents]), html)
    @test occursin("Binding constraints", html)
    @test occursin("Scenario sensitivity", html)
    @test occursin("Accepted tradeoffs", html)
    @test occursin("Approve", html)
    @test occursin("Reject", html)
    @test occursin("Export CSV", html)
    @test occursin("/api/recommendations/$(rec[:id])/approve", html)
    @test !occursin("Kōwhai", html)

    @test_throws ApiError render_recommendation_detail_page(store, BATCH012_VIEWER_A, string(UUID("d0000000-0000-4000-8000-000000000099")))
end
