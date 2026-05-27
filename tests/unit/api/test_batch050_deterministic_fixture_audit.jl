using Test
using JSON3
using InventoryAllocationSimulator

function batch050_solver_fixture()
    fixture, snapshot, scenarios = batch021_solver_fixture_snapshot()
    return fixture, snapshot, scenarios
end

@testset "Batch 050 deterministic fixture produces expected transfer plan and explanation" begin
    fixture, snapshot, scenarios = batch050_solver_fixture()

    result = solve_allocation_model(snapshot, scenarios; config = AllocationSolverConfig(timeout_seconds = 30.0, max_gap = 0.05, min_transfer_units = 1.0))

    @test result.status == "optimal"
    recommendation = only(result.recommendations)
    expected = fixture.expectedRecommendation
    @test snapshot.warehouses[1].code == expected.from
    @test snapshot.warehouses[2].code == expected.to
    @test snapshot.skus[1].sku_code == expected.sku_code
    @test recommendation.from_warehouse_id == snapshot.transfer_lanes[1].from_warehouse_id
    @test recommendation.to_warehouse_id == snapshot.transfer_lanes[1].to_warehouse_id
    @test recommendation.sku_id == snapshot.skus[1].id
    @test recommendation.transfer_units ≈ Float64(expected.transfer_units) atol = 0.0001
    @test recommendation.expected_stockout_reduction_units ≈ Float64(expected.transfer_units) atol = 0.0001
    @test recommendation.transfer_cost_cents == Int(expected.transfer_units) * Int(fixture.lane.cost_per_unit_cents)
    @test recommendation.net_value_cents == Int(expected.net_value_cents)

    explanation = recommendation.explanation
    @test Set(explanation["binding_constraints"]) == Set(String.(expected.binding_constraints))
    @test explanation["scenario_sensitivity"]["scenario_count"] == length(scenarios)
    expected_unmet_after = (1.0 - Float64(fixture.policy.service_level_target)) * explanation["scenario_sensitivity"]["expected_demand_units"]
    @test explanation["scenario_sensitivity"]["shortage_before_units"] ≈ Float64(expected.transfer_units) + expected_unmet_after atol = 0.0001
    @test explanation["scenario_sensitivity"]["unmet_after_units"] ≈ expected_unmet_after atol = 0.0001
    @test Set(explanation["accepted_tradeoffs"]) == Set(["transfer_cost", "sender_safety_stock", "receiver_service_level"])
    @test explanation["net_value"]["net_value_cents"] == recommendation.net_value_cents
    @test explanation["solver"]["status"] in ["OPTIMAL", "LOCALLY_SOLVED"]
end

@testset "Batch 050 deterministic fixture audit gate is rerunnable" begin
    script = joinpath(project_root(), ".yolo", "scripts", "validate-batch-050-deterministic-solver-audit.sh")
    @test isfile(script)
    source = isfile(script) ? read(script, String) : ""
    for token in [
        "solver_small_network.json",
        "test_batch050_deterministic_fixture_audit.jl",
        "expected.transfer_units",
        "binding_constraints",
        "scenario_sensitivity",
        "accepted_tradeoffs",
        "recommendation_net_value",
    ]
        @test occursin(token, source)
    end
end
