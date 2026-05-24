using Test
using Dates
using UUIDs
using JSON3
using DuckDB
using InventoryAllocationSimulator

function batch021_solver_fixture_snapshot()
    fixture = JSON3.read(read(joinpath(project_root(), "tests", "fixtures", "correctness", "solver_small_network.json"), String))
    tenant = string(BATCH012_TENANT_A)
    surplus = "10000000-0021-4000-8000-000000000001"
    need = "10000000-0021-4000-8000-000000000002"
    sku = "30000000-0021-4000-8000-000000000001"
    expected_transfer = Float64(fixture.expectedRecommendation.transfer_units)
    horizon = Int(fixture.policy.planning_horizon_days)
    demand_units = (10.0 + expected_transfer) / Float64(fixture.policy.service_level_target)
    snapshot = (
        tenant_id = tenant,
        policy = (
            id = "b0000000-0021-4000-8000-000000000001",
            tenant_id = tenant,
            name = "Small network optimum",
            objective = String(fixture.policy.objective),
            planning_horizon_days = horizon,
            service_level_target = Float64(fixture.policy.service_level_target),
            max_transfer_cost_cents = nothing,
            allow_cross_region = Bool(fixture.policy.allow_cross_region),
            frozen_until = nothing,
            config = Dict{String,Any}(),
            status = "active",
        ),
        warehouses = [
            (id = surplus, tenant_id = tenant, code = String(fixture.warehouses[1].code), name = "Surplus DC", region = String(fixture.warehouses[1].region), latitude = nothing, longitude = nothing, capacity_units = Float64(fixture.warehouses[1].capacity_units), handling_cost_cents = 0, active = true),
            (id = need, tenant_id = tenant, code = String(fixture.warehouses[2].code), name = "Need DC", region = String(fixture.warehouses[2].region), latitude = nothing, longitude = nothing, capacity_units = Float64(fixture.warehouses[2].capacity_units), handling_cost_cents = 0, active = true),
        ],
        skus = [(id = sku, tenant_id = tenant, sku_code = String(fixture.sku.sku_code), name = "Fast SKU", category = "fast", unit_volume = 1.0, unit_margin_cents = Int(fixture.sku.unit_margin_cents), stockout_cost_cents = Int(fixture.sku.stockout_cost_cents), holding_cost_cents = Int(fixture.sku.holding_cost_cents), active = true)],
        inventory_positions = [
            (id = "50000000-0021-4000-8000-000000000001", tenant_id = tenant, warehouse_id = surplus, sku_id = sku, on_hand_units = Float64(fixture.inventory[1].on_hand_units), reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = Float64(fixture.inventory[1].safety_stock_units), available_units = Float64(fixture.inventory[1].on_hand_units), as_of = "2026-05-01T09:00:00", source = "manual"),
            (id = "50000000-0021-4000-8000-000000000002", tenant_id = tenant, warehouse_id = need, sku_id = sku, on_hand_units = Float64(fixture.inventory[2].on_hand_units), reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = Float64(fixture.inventory[2].safety_stock_units), available_units = Float64(fixture.inventory[2].on_hand_units), as_of = "2026-05-01T09:00:00", source = "manual"),
        ],
        transfer_lanes = [(id = "90000000-0021-4000-8000-000000000001", tenant_id = tenant, from_warehouse_id = surplus, to_warehouse_id = need, lead_time_days = Int(fixture.lane.lead_time_days), cost_per_unit_cents = Int(fixture.lane.cost_per_unit_cents), capacity_units_day = expected_transfer / horizon, active = true)],
    )
    scenarios = [(
        id = "d0000000-0021-4000-8000-000000000001",
        tenant_id = tenant,
        simulation_run_id = "e0000000-0021-4000-8000-000000000001",
        scenario_index = 1,
        probability_weight = 1.0,
        demand_payload = Dict{String,Any}("demands" => [Dict{String,Any}("warehouse_id" => need, "sku_id" => sku, "demand_units" => demand_units, "baseline_units" => demand_units, "uncertainty_units" => 0.0, "stockout_periods" => 0)]),
    )]
    return fixture, snapshot, scenarios
end

function batch021_config(duckdb_path::AbstractString)
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => String(duckdb_path),
        "SESSION_SECRET" => "batch021-session-secret-placeholder",
        "METRICS_TOKEN" => "batch021-metrics-token-placeholder",
    ))
end

@testset "Batch 021 deterministic small network proves known optimum and shared net value" begin
    fixture, snapshot, scenarios = batch021_solver_fixture_snapshot()

    result = solve_allocation_model(snapshot, scenarios; config = AllocationSolverConfig(timeout_seconds = 30.0, max_gap = 0.05, min_transfer_units = 1.0))

    @test result.status == "optimal"
    rec = only(result.recommendations)
    @test rec.from_warehouse_id == snapshot.transfer_lanes[1].from_warehouse_id
    @test rec.to_warehouse_id == snapshot.transfer_lanes[1].to_warehouse_id
    @test rec.sku_id == snapshot.skus[1].id
    @test rec.transfer_units ≈ Float64(fixture.expectedRecommendation.transfer_units) atol = 0.0001
    @test rec.expected_stockout_reduction_units ≈ Float64(fixture.expectedRecommendation.transfer_units) atol = 0.0001
    @test rec.transfer_cost_cents == Int(fixture.expectedRecommendation.transfer_units) * Int(fixture.lane.cost_per_unit_cents)
    @test rec.net_value_cents == Int(fixture.expectedRecommendation.net_value_cents)
    @test rec.explanation["net_value"]["net_value_cents"] == rec.net_value_cents
    @test "lane_capacity" in rec.explanation["binding_constraints"]
    @test "receiver_service_level" in rec.explanation["binding_constraints"]

    canonical = recommendation_net_value(
        expected_benefit_cents = rec.explanation["net_value"]["expected_benefit_cents"],
        expected_margin_gain_cents = rec.expected_margin_gain_cents,
        transfer_cost_cents = rec.transfer_cost_cents,
        holding_cost_cents = rec.explanation["net_value"]["holding_cost_cents"],
    )
    @test canonical.net_value_cents == rec.net_value_cents
end

@testset "Batch 021 deterministic small network suppresses uneconomic tiny transfers" begin
    _, snapshot, scenarios = batch021_solver_fixture_snapshot()

    result = solve_allocation_model(snapshot, scenarios; config = AllocationSolverConfig(timeout_seconds = 30.0, max_gap = 0.05, min_transfer_units = 31.0))

    @test result.status == "optimal"
    @test isempty(result.recommendations)
    @test occursin("MIN_TRANSFER_UNITS", result.diagnostics["message"])
end

@testset "Batch 021 daily backtest evaluates active policy quality and tenant scope" begin
    store = batch012_store()

    reports = run_daily_backtest!(store, BATCH012_ADMIN_A; as_of = DateTime(2026, 5, 1, 2), lookback_days = 60)

    @test length(reports) == 1
    report = only(reports)
    @test report.tenant_id == string(BATCH012_TENANT_A)
    @test report.policy_id == "b0000000-0000-4000-8000-000000000001"
    @test report.periods == 2
    @test report.observed_demand_units == 88.0
    @test report.adjusted_demand_units == 103.0
    @test report.service_score ≈ 88.0 / 103.0 atol = 0.0001
    @test report.quality_status == "degraded"
    @test all(item.tenant_id != string(BATCH012_TENANT_B) for item in reports)
end

@testset "Batch 021 daily backtest rejects invalid lookback and respects schedule" begin
    store = batch012_store()

    @test_throws ApiError run_daily_backtest!(store, BATCH012_ADMIN_A; as_of = DateTime(2026, 5, 1, 2), lookback_days = 0)
    @test daily_backtest_due(DateTime(2026, 5, 1, 1, 59), nothing) == false
    @test daily_backtest_due(DateTime(2026, 5, 1, 2, 0), nothing) == true
    @test daily_backtest_due(DateTime(2026, 5, 1, 12, 0), Date(2026, 5, 1)) == false
    @test daily_backtest_due(DateTime(2026, 5, 2, 2, 0), Date(2026, 5, 1)) == true
end

@testset "Batch 021 daily backtest job persists DuckDB evidence and is wired" begin
    store = batch012_store()
    duckdb_path = tempname() * ".duckdb"
    config = batch021_config(duckdb_path)

    service = build_job_service()
    @test "daily_backtest" in service.queues
    summary = run_due_daily_backtest!(service, store, config, [BATCH012_ADMIN_A]; now = DateTime(2026, 5, 1, 2, 0))

    @test summary.ran == true
    @test summary.results_written == 1
    @test service.last_backtest_run_date == Date(2026, 5, 1)
    second = run_due_daily_backtest!(service, store, config, [BATCH012_ADMIN_A]; now = DateTime(2026, 5, 1, 3, 0))
    @test second.ran == false
    @test second.results_written == 0

    db = DuckDB.DB(duckdb_path)
    con = DuckDB.connect(db)
    rows = collect(DuckDB.execute(con, "SELECT tenant_id, policy_id, quality_status, service_score FROM policy_backtest_results ORDER BY policy_id"))
    close(con)
    close(db)
    @test length(rows) == 1
    @test string(rows[1].tenant_id) == string(BATCH012_TENANT_A)
    @test string(rows[1].policy_id) == "b0000000-0000-4000-8000-000000000001"
    @test string(rows[1].quality_status) == "degraded"
    @test Float64(rows[1].service_score) ≈ 88.0 / 103.0 atol = 0.0001
    rm(duckdb_path; force = true)
end
