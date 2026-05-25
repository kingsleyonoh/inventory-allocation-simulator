using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

function batch019_stockout_store()
    store = batch012_store()
    wh = UUID("10000000-0000-4000-8000-000000000001")
    sku = UUID("30000000-0000-4000-8000-000000000001")
    empty!(store.demand_history)
    rows = [
        (Date(2026, 1, 1), 70.0, 0.0),
        (Date(2026, 1, 8), 74.0, 0.0),
        (Date(2026, 1, 15), 0.0, 82.0),
        (Date(2026, 1, 22), 76.0, 0.0),
    ]
    for (idx, (start, demand, lost)) in enumerate(rows)
        id = UUID("71000000-0000-4000-8000-00000000000$(idx)")
        store.demand_history[id] = Dict{Symbol,Any}(
            :id => id,
            :tenant_id => BATCH012_TENANT_A,
            :warehouse_id => wh,
            :sku_id => sku,
            :period_start => start,
            :period_end => start + Day(6),
            :demand_units => demand,
            :lost_sales_units => lost,
            :source => "manual",
        )
    end
    return store
end

@testset "Batch 019 simulation API routes are registered and protected" begin
    definitions = route_definitions()
    expected = Set([
        (:POST, "/api/simulations"),
        (:GET, "/api/simulations"),
        (:GET, "/api/simulations/:id"),
        (:POST, "/api/simulations/:id/cancel"),
    ])
    actual = Set((def.method, def.path) for def in definitions)
    @test issubset(expected, actual)

    controller = read(joinpath(project_root(), "src", "web", "controllers", "simulation_controller.jl"), String)
    for handler in ["handle_create_simulation", "handle_list_simulations", "handle_get_simulation", "handle_cancel_simulation"]
        handler_start = findfirst("function $handler", controller)
        @test handler_start !== nothing
        next_handler = findnext("function ", controller, last(handler_start) + 1)
        block = next_handler === nothing ? controller[first(handler_start):end] : controller[first(handler_start):first(next_handler)-1]
        @test occursin("_enforce_route_rate_limit!", block)
        @test occursin("_protected_context_and_store", block)
    end
end

@testset "Simulation lifecycle freezes snapshots and enforces idempotent run creation" begin
    store = batch012_store()
    policy_id = "b0000000-0000-4000-8000-000000000001"

    run = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Batch 019 replay", "scenario_count" => 4); idempotency_key = "batch-019-key")
    duplicate = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Batch 019 replay", "scenario_count" => 4); idempotency_key = "batch-019-key")
    @test run.id == duplicate.id
    @test run.status == "queued"
    @test run.created_by_user_id == string(BATCH012_PLANNER_A.user_id)
    @test run.input_snapshot.policy.name == "Balanced baseline"
    @test first(filter(row -> row.sku_id == "30000000-0000-4000-8000-000000000001", run.input_snapshot.inventory_positions)).on_hand_units == 100.0

    listed = list_simulation_runs(store, BATCH012_VIEWER_A; params = Dict("status" => "queued")).simulation_runs
    @test [item.id for item in listed] == [run.id]

    frozen_demand = first(filter(row -> row.sku_id == "30000000-0000-4000-8000-000000000001", run.input_snapshot.demand_history))
    @test frozen_demand.stockout_adjusted_demand_units == 95.0

    store.inventory_positions[UUID("50000000-0000-4000-8000-000000000001")][:on_hand_units] = 1.0
    store.demand_history[UUID("70000000-0000-4000-8000-000000000001")][:demand_units] = 10_000.0
    completed = simulation_worker!(store, BATCH012_ADMIN_A; worker_id = "worker-019", seed = 19019)
    @test completed.status == "completed"
    detail = get_simulation_run(store, BATCH012_VIEWER_A, run.id)
    @test detail.status == "completed"
    @test length(detail.scenarios) == 4
    first_scenario_demand = only(filter(item -> item["sku_id"] == "30000000-0000-4000-8000-000000000001", detail.scenarios[1].demand_payload["demands"]))
    @test first_scenario_demand["baseline_units"] == 95.0
    @test first_scenario_demand["baseline_units"] != 10015.0
    @test first(filter(row -> row.sku_id == "30000000-0000-4000-8000-000000000001", detail.input_snapshot.inventory_positions)).on_hand_units == 100.0
    @test list_inventory_positions(store, BATCH012_VIEWER_A).inventory[1].on_hand_units == 1.0

    @test_throws AuthzError create_simulation_run!(store, BATCH012_VIEWER_A, Dict("policy_id" => policy_id, "name" => "Denied"))
    @test_throws ApiError cancel_simulation_run!(store, BATCH012_PLANNER_A, run.id)

    @test hasmethod(claim_next_simulation_run_for_system!, Tuple{SqlTenantAdminStore})
    @test hasmethod(simulation_worker!, Tuple{SqlTenantAdminStore, AppConfig})
    @test hasmethod(reap_stale_simulation_runs!, Tuple{SqlTenantAdminStore, AppConfig})
end

@testset "Simulation cancellation and stale-run reaper use lifecycle rules" begin
    store = batch012_store()
    policy_id = "b0000000-0000-4000-8000-000000000001"
    queued = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Cancel me"))
    cancelled = cancel_simulation_run!(store, BATCH012_PLANNER_A, queued.id)
    @test cancelled.status == "cancelled"
    @test_throws AuthzError cancel_simulation_run!(store, BATCH012_VIEWER_A, queued.id)

    racing = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Cancel while running"))
    claimed = claim_next_simulation_run!(store, BATCH012_ADMIN_A; worker_id = "worker-race", now = DateTime(2026, 5, 24, 9))
    @test string(claimed[:id]) == racing.id
    running_cancelled = cancel_simulation_run!(store, BATCH012_PLANNER_A, racing.id)
    @test running_cancelled.status == "cancelled"
    worker_completion = InventoryAllocationSimulator.complete_simulation_run!(store, claimed)
    @test worker_completion.status == "cancelled"
    @test get_simulation_run(store, BATCH012_VIEWER_A, racing.id).status == "cancelled"

    stale = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Stale run"))
    claim_next_simulation_run!(store, BATCH012_ADMIN_A; worker_id = "worker-stale", now = DateTime(2026, 5, 24, 10))
    reaped = reap_stale_simulation_runs!(store, BATCH012_ADMIN_A; stale_after_minutes = 30, now = DateTime(2026, 5, 24, 10, 31))
    @test reaped == 1
    @test get_simulation_run(store, BATCH012_VIEWER_A, stale.id).status == "failed"
    @test occursin("stale", get_simulation_run(store, BATCH012_VIEWER_A, stale.id).error_message)
end

@testset "Stockout-aware demand cleaning prevents low-demand forecasts" begin
    store = batch019_stockout_store()
    preview = forecast_preview(store, BATCH012_VIEWER_A, UUID("b0000000-0000-4000-8000-000000000001"); scenario_count = 3)
    forecast = only(preview.forecasts)

    observed_average = (70.0 + 74.0 + 0.0 + 76.0) / 4
    adjusted_average = (70.0 + 74.0 + 82.0 + 76.0) / 4
    @test forecast.stockout_periods == 1
    @test forecast.baseline_units >= adjusted_average - 5
    @test forecast.baseline_units > observed_average + 15
    @test forecast.uncertainty_units > 0

    cleaned = clean_demand_history(fetch_demand_history(store, BATCH012_TENANT_A, CursorPageRequest(100, nothing, Dict{String,String}())))
    stockout = only(filter(row -> row.stockout_adjusted, cleaned))
    @test stockout.adjusted_units == 82.0
    @test stockout.observed_units == 0.0
end

@testset "Probabilistic scenario generation is deterministic and stored per run" begin
    store = batch019_stockout_store()
    policy_id = "b0000000-0000-4000-8000-000000000001"
    run_a = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Scenario A", "scenario_count" => 3))
    scenarios_a = generate_demand_scenarios!(store, BATCH012_PLANNER_A, run_a.id; seed = 20260524)
    @test length(scenarios_a) == 3
    @test sum(s.probability_weight for s in scenarios_a) ≈ 1.0 atol = 0.000001
    @test length(get_simulation_run(store, BATCH012_VIEWER_A, run_a.id).scenarios) == 3

    run_b = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Scenario B", "scenario_count" => 3))
    scenarios_b = generate_demand_scenarios!(store, BATCH012_PLANNER_A, run_b.id; seed = 20260524)
    @test [s.demand_payload for s in scenarios_a] == [s.demand_payload for s in scenarios_b]

    run_c = create_simulation_run!(store, BATCH012_PLANNER_A, Dict("policy_id" => policy_id, "name" => "Scenario C", "scenario_count" => 3))
    scenarios_c = generate_demand_scenarios!(store, BATCH012_PLANNER_A, run_c.id; seed = 20260525)
    @test [s.demand_payload for s in scenarios_a] != [s.demand_payload for s in scenarios_c]
    @test_throws AuthzError generate_demand_scenarios!(store, BATCH012_VIEWER_A, run_a.id; seed = 1)
end

@testset "SQL simulation idempotency and worker paths are production-wired" begin
    migration = replace(lowercase(read(joinpath(project_root(), "migrations", "002_operational_data_spine.up.sql"), String)), r"\s+" => " ")
    @test occursin("idempotency_key text null", migration)
    @test occursin("create unique index if not exists simulation_runs_tenant_idempotency_key_idx on simulation_runs (tenant_id, idempotency_key) where idempotency_key is not null", migration)

    simulation_sources = [
        "simulations.jl",
        "simulations_lifecycle.jl",
        "simulations_memory_store.jl",
        "simulations_sql_store.jl",
    ]
    source = replace(lowercase(join(read(joinpath(project_root(), "src", "planning", file), String) for file in simulation_sources)), r"\s+" => " ")
    @test !occursin("fetch_simulation_run_by_idempotency_key(store::sqltenantadminstore, tenant_id::uuid, key::string) = nothing", source)
    @test occursin(raw"idempotency_key = \$2", source)
    @test occursin("idempotency_key)", source)
    @test occursin("claim_next_simulation_run!(store, ctx", source)
    @test occursin("reap_stale_simulation_runs!(store, ctx", source)
    @test occursin("and status = 'running'", source)
end
