using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

function batch020_stockout_rows_from_fixture()
    fixture = JSON3.read(read(joinpath(project_root(), "tests", "fixtures", "correctness", "forecast_stockout_history.json"), String))
    tenant_id = UUID(String(fixture.tenant_id))
    wh = UUID("11111111-0000-4111-8111-111111111111")
    sku = UUID("22222222-0000-4222-8222-222222222222")
    rows = Dict{Symbol,Any}[]
    for (idx, period) in enumerate(fixture.periods)
        push!(rows, Dict{Symbol,Any}(
            :id => uuid5(UUID("00000000-0000-0000-0000-000000000000"), "stockout-$idx"),
            :tenant_id => tenant_id,
            :warehouse_id => wh,
            :sku_id => sku,
            :period_start => Date(String(period.period_start)),
            :period_end => Date(String(period.period_end)),
            :demand_units => Float64(period.demand_units),
            :lost_sales_units => Float64(period.lost_sales_units),
            :source => "manual",
        ))
    end
    return rows, Float64(fixture.minimumCleanedDemandAverage)
end

function batch020_solver_snapshot(; objective = "minimize_stockout_cost", allow_cross_region = true, max_transfer_cost_cents = nothing, demand_units = 42.1052631579, lane_capacity = 200.0, service_level = 0.95)
    tenant = string(BATCH012_TENANT_A)
    surplus = "10000000-0000-4000-8000-000000001001"
    need = "10000000-0000-4000-8000-000000001002"
    sku = "30000000-0000-4000-8000-000000001001"
    snapshot = (
        tenant_id = tenant,
        policy = (
            id = "b0000000-0000-4000-8000-000000001001", tenant_id = tenant, name = "Batch 020 policy",
            objective = objective, planning_horizon_days = 1, service_level_target = service_level,
            max_transfer_cost_cents = max_transfer_cost_cents, allow_cross_region = allow_cross_region,
            frozen_until = nothing, config = Dict{String,Any}(), status = "active",
        ),
        warehouses = [
            (id = surplus, tenant_id = tenant, code = "WH-SURPLUS", name = "Surplus", region = "North", latitude = nothing, longitude = nothing, capacity_units = 500.0, handling_cost_cents = 0, active = true),
            (id = need, tenant_id = tenant, code = "WH-NEED", name = "Need", region = "South", latitude = nothing, longitude = nothing, capacity_units = 500.0, handling_cost_cents = 0, active = true),
        ],
        skus = [(id = sku, tenant_id = tenant, sku_code = "SKU-FAST", name = "Fast SKU", category = "fast", unit_volume = 1.0, unit_margin_cents = 900, stockout_cost_cents = 1200, holding_cost_cents = 0, active = true)],
        inventory_positions = [
            (id = "50000000-0000-4000-8000-000000001001", tenant_id = tenant, warehouse_id = surplus, sku_id = sku, on_hand_units = 100.0, reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = 70.0, available_units = 100.0, as_of = "2026-05-01T09:00:00", source = "manual"),
            (id = "50000000-0000-4000-8000-000000001002", tenant_id = tenant, warehouse_id = need, sku_id = sku, on_hand_units = 10.0, reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = 20.0, available_units = 10.0, as_of = "2026-05-01T09:00:00", source = "manual"),
        ],
        transfer_lanes = [(id = "90000000-0000-4000-8000-000000001001", tenant_id = tenant, from_warehouse_id = surplus, to_warehouse_id = need, lead_time_days = 1, cost_per_unit_cents = 150, capacity_units_day = lane_capacity, active = true)],
    )
    scenarios = [(
        id = "d0000000-0000-4000-8000-000000001001", tenant_id = tenant, simulation_run_id = "e0000000-0000-4000-8000-000000001001",
        scenario_index = 1, probability_weight = 1.0,
        demand_payload = Dict{String,Any}("demands" => [Dict{String,Any}("warehouse_id" => need, "sku_id" => sku, "demand_units" => demand_units, "baseline_units" => demand_units, "uncertainty_units" => 2.0, "stockout_periods" => 0)]),
    )]
    return snapshot, scenarios
end

function batch020_worker_store()
    snapshot, _ = batch020_solver_snapshot(objective = "balanced", demand_units = 42.0)
    store = batch012_store()
    empty!(store.warehouses)
    empty!(store.skus)
    empty!(store.inventory_positions)
    empty!(store.demand_history)
    empty!(store.transfer_lanes)
    empty!(store.allocation_policies)

    for wh in snapshot.warehouses
        store.warehouses[UUID(wh.id)] = Dict{Symbol,Any}(name => getproperty(wh, name) for name in propertynames(wh))
        store.warehouses[UUID(wh.id)][:id] = UUID(wh.id)
        store.warehouses[UUID(wh.id)][:tenant_id] = UUID(wh.tenant_id)
    end
    for sku in snapshot.skus
        store.skus[UUID(sku.id)] = Dict{Symbol,Any}(name => getproperty(sku, name) for name in propertynames(sku))
        store.skus[UUID(sku.id)][:id] = UUID(sku.id)
        store.skus[UUID(sku.id)][:tenant_id] = UUID(sku.tenant_id)
    end
    for inv in snapshot.inventory_positions
        row = Dict{Symbol,Any}(name => getproperty(inv, name) for name in propertynames(inv) if name != :available_units)
        row[:id] = UUID(inv.id)
        row[:tenant_id] = UUID(inv.tenant_id)
        row[:warehouse_id] = UUID(inv.warehouse_id)
        row[:sku_id] = UUID(inv.sku_id)
        row[:as_of] = DateTime(2026, 5, 1, 9)
        store.inventory_positions[row[:id]] = row
    end
    for lane in snapshot.transfer_lanes
        row = Dict{Symbol,Any}(name => getproperty(lane, name) for name in propertynames(lane))
        row[:id] = UUID(lane.id)
        row[:tenant_id] = UUID(lane.tenant_id)
        row[:from_warehouse_id] = UUID(lane.from_warehouse_id)
        row[:to_warehouse_id] = UUID(lane.to_warehouse_id)
        store.transfer_lanes[row[:id]] = row
    end

    policy = snapshot.policy
    policy_row = Dict{Symbol,Any}(name => getproperty(policy, name) for name in propertynames(policy))
    policy_row[:id] = UUID(policy.id)
    policy_row[:tenant_id] = UUID(policy.tenant_id)
    store.allocation_policies[policy_row[:id]] = policy_row
    demand_id = UUID("70000000-0000-4000-8000-000000001001")
    store.demand_history[demand_id] = Dict{Symbol,Any}(
        :id => demand_id, :tenant_id => BATCH012_TENANT_A,
        :warehouse_id => UUID(snapshot.transfer_lanes[1].to_warehouse_id), :sku_id => UUID(snapshot.skus[1].id),
        :period_start => Date(2026, 4, 1), :period_end => Date(2026, 4, 7),
        :demand_units => 42.0, :lost_sales_units => 0.0, :source => "manual",
    )
    return store, policy.id
end

@testset "Batch 020 stockout correctness fixture does not depress forecast demand" begin
    rows, minimum_average = batch020_stockout_rows_from_fixture()
    cleaned = clean_demand_history(rows)
    observed_average = sum(row.observed_units for row in cleaned) / length(cleaned)
    adjusted_average = sum(row.adjusted_units for row in cleaned) / length(cleaned)
    stockout_rows = filter(row -> row.stockout_adjusted, cleaned)

    @test length(stockout_rows) == 2
    @test adjusted_average >= minimum_average
    @test adjusted_average > observed_average * 1.75

    preview = InventoryAllocationSimulator.forecast_preview_from_snapshot((policy = (id = "fixture-policy", name = "Fixture policy"), demand_history = rows); scenario_count = 4)
    forecast = only(preview.forecasts)
    @test forecast.baseline_units >= minimum_average
    @test forecast.baseline_units > observed_average * 1.75
    @test forecast.uncertainty_units > 0
end

@testset "Batch 020 allocation model respects stock lane capacity service safety region and cost constraints" begin
    snapshot, scenarios = batch020_solver_snapshot()
    result = solve_allocation_model(snapshot, scenarios; config = AllocationSolverConfig(timeout_seconds = 30.0, max_gap = 0.05, min_transfer_units = 1.0))
    @test result.status == "optimal"
    rec = only(result.recommendations)
    @test rec.transfer_units ≈ 30.0 atol = 0.0001
    @test rec.expected_stockout_reduction_units ≈ 30.0 atol = 0.0001
    @test rec.transfer_cost_cents == 4500
    @test rec.net_value_cents == 31500
    @test "sender_safety_stock" in rec.explanation["binding_constraints"]
    @test "receiver_service_level" in rec.explanation["binding_constraints"]

    low_cost_snapshot, low_cost_scenarios = batch020_solver_snapshot(max_transfer_cost_cents = 1_000)
    low_cost = solve_allocation_model(low_cost_snapshot, low_cost_scenarios)
    @test low_cost.status == "failed"
    @test low_cost.diagnostics["solver_status"] == "INFEASIBLE"
    @test any(occursin("max_transfer_cost", item) for item in low_cost.diagnostics["constraint_report"])

    regional_snapshot, regional_scenarios = batch020_solver_snapshot(allow_cross_region = false)
    regional = solve_allocation_model(regional_snapshot, regional_scenarios)
    @test regional.status == "failed"
    @test any(occursin("region", item) for item in regional.diagnostics["constraint_report"])
end

@testset "Batch 020 solver reports diagnostics when source inventory row is missing" begin
    snapshot, scenarios = batch020_solver_snapshot()
    source_warehouse_id = snapshot.transfer_lanes[1].from_warehouse_id
    sku_id = snapshot.skus[1].id
    sparse_snapshot = merge(snapshot, (
        inventory_positions = [item for item in snapshot.inventory_positions if !(item.warehouse_id == source_warehouse_id && item.sku_id == sku_id)],
    ))

    result = solve_allocation_model(sparse_snapshot, scenarios)
    @test result.status == "failed"
    @test result.diagnostics["solver_status"] == "INFEASIBLE"
    @test occursin("solver did not produce an acceptable solution", result.diagnostics["message"])
    @test !occursin("KeyError", result.diagnostics["message"])
end

@testset "Batch 020 allocation objectives timeout gap confidence and explanations are deterministic" begin
    for (objective, expected_net) in [
        ("minimize_stockout_cost", 31500),
        ("maximize_margin", 22500),
        ("minimize_total_cost", 31500),
        ("balanced", 58500),
    ]
        snapshot, scenarios = batch020_solver_snapshot(objective = objective)
        result = solve_allocation_model(snapshot, scenarios)
        @test result.status == "optimal"
        rec = only(result.recommendations)
        @test rec.net_value_cents == expected_net
        @test 0.0 <= rec.confidence_score <= 1.0
        @test rec.explanation["objective"] == objective
        @test rec.explanation["scenario_sensitivity"]["scenario_count"] == 1
        @test rec.explanation["net_value"] == Dict{String,Any}(
            "expected_benefit_cents" => rec.explanation["net_value"]["expected_benefit_cents"],
            "expected_margin_gain_cents" => rec.expected_margin_gain_cents,
            "transfer_cost_cents" => rec.transfer_cost_cents,
            "holding_cost_cents" => rec.explanation["net_value"]["holding_cost_cents"],
            "net_value_cents" => rec.net_value_cents,
        )
    end

    timed_snapshot, timed_scenarios = batch020_solver_snapshot()
    timed = solve_allocation_model(timed_snapshot, timed_scenarios; config = AllocationSolverConfig(timeout_seconds = 0.0, max_gap = 0.05, min_transfer_units = 1.0))
    @test timed.status == "failed"
    @test timed.diagnostics["solver_status"] == "TIME_LIMIT"
    @test occursin("timeout", timed.diagnostics["message"])

    gapped = solver_outcome_decision("TIME_LIMIT", 0.04, true, 0.05)
    @test gapped.accepted == true
    @test gapped.reason == "TIME_LIMIT_GAP_ACCEPTED"
    rejected = solver_outcome_decision("TIME_LIMIT", 0.08, true, 0.05)
    @test rejected.accepted == false
    @test rejected.reason == "TIME_LIMIT_GAP_EXCEEDED"
end

@testset "Batch 020 solver exports and worker recommendation wiring are live" begin
    @test isdefined(InventoryAllocationSimulator, :AllocationSolverConfig)
    @test isdefined(InventoryAllocationSimulator, :solve_allocation_model)
    @test isdefined(InventoryAllocationSimulator, :generate_allocation_recommendations!)
    @test hasmethod(solve_allocation_model, Tuple{Any,Any})
    @test hasmethod(generate_allocation_recommendations!, Tuple{AbstractTenantAdminStore,TenantContext,Any})

    store, policy_id = batch020_worker_store()
    run = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Solver worker", "scenario_count" => 1))
    completed = simulation_worker!(store, BATCH012_ADMIN_A; worker_id = "worker-020", seed = 1)
    @test completed.status == "completed"
    @test completed.error_message === nothing
    persisted = [row for row in values(store.allocation_recommendations) if row[:simulation_run_id] == UUID(run.id)]
    @test length(persisted) == 1
    rec = only(persisted)
    @test rec[:transfer_units] ≈ 30.0 atol = 0.0001
    @test rec[:net_value_cents] == 58500
end

@testset "Batch 020 solver reports readable worker failures without demand history" begin
    store = batch012_store()
    empty!(store.demand_history)
    policy_id = "b0000000-0000-4000-8000-000000000001"
    create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Solver worker", "scenario_count" => 1))
    completed = simulation_worker!(store, BATCH012_ADMIN_A; worker_id = "worker-020", seed = 20260524)
    @test completed.status == "failed"
    @test occursin("demand history", completed.error_message)

    snapshot, scenarios = batch020_solver_snapshot()
    solver_result = solve_allocation_model(snapshot, scenarios)
    @test !isempty(solver_result.recommendations)
end

@testset "Batch 020 simulation worker preserves solver constraint reports on failed runs" begin
    store, policy_id = batch020_worker_store()
    policy_uuid = UUID(policy_id)
    store.allocation_policies[policy_uuid][:max_transfer_cost_cents] = 1_000
    create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Infeasible solver worker", "scenario_count" => 1))

    completed = simulation_worker!(store, BATCH012_ADMIN_A; worker_id = "worker-020-infeasible", seed = 1)

    @test completed.status == "failed"
    @test occursin("SOLVER_FAILED", completed.error_message)
    @test occursin("constraint_report", completed.error_message)
    @test occursin("max_transfer_cost_cents=1000", completed.error_message)
    @test occursin("sender safety stock", completed.error_message)
end
