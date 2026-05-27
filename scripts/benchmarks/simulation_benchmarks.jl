const LARGE_SIMULATION_SCENARIO_COUNT = 100

function _large_benchmark_uuid(prefix::Integer, index::Integer)::UUID
    return UUID("$(lpad(prefix, 8, '0'))-0053-4000-8000-$(lpad(index, 12, '0'))")
end

function _large_simulation_policy(tenant_id::UUID)::NamedTuple
    return (
        id = _large_benchmark_uuid(53, 1), tenant_id = tenant_id, name = "Large simulation benchmark policy",
        objective = "balanced", planning_horizon_days = 30, service_level_target = 0.90,
        max_transfer_cost_cents = nothing, allow_cross_region = true, frozen_until = nothing,
        config = Dict{String,Any}(), status = "active",
    )
end

function _large_simulation_warehouses(fixture::PerformanceBenchmarkFixture)::Vector{NamedTuple}
    return [merge(warehouse, (latitude = nothing, longitude = nothing, capacity_units = 1_000_000.0,)) for warehouse in fixture.warehouses]
end

function _large_simulation_inventory(fixture::PerformanceBenchmarkFixture)::Vector{NamedTuple}
    source = fixture.warehouses[1]
    destination = fixture.warehouses[2]
    rows = NamedTuple[]
    for (idx, sku) in enumerate(fixture.skus)
        push!(rows, (
            id = _large_benchmark_uuid(54, idx), tenant_id = fixture.tenant_id, warehouse_id = source.id, sku_id = sku.id,
            on_hand_units = 250.0 + mod(idx, 20), reserved_units = 0.0, inbound_units = 0.0,
            safety_stock_units = 20.0, as_of = DateTime(2026, 5, 27), source = "benchmark",
        ))
        push!(rows, (
            id = _large_benchmark_uuid(55, idx), tenant_id = fixture.tenant_id, warehouse_id = destination.id, sku_id = sku.id,
            on_hand_units = 5.0, reserved_units = 0.0, inbound_units = 0.0,
            safety_stock_units = 10.0, as_of = DateTime(2026, 5, 27), source = "benchmark",
        ))
    end
    return rows
end

function _large_simulation_demand(fixture::PerformanceBenchmarkFixture)::Vector{NamedTuple}
    destination = fixture.warehouses[2]
    return [(
        id = _large_benchmark_uuid(56, idx), tenant_id = fixture.tenant_id, warehouse_id = destination.id, sku_id = sku.id,
        period_start = Date(2026, 5, 1), period_end = Date(2026, 5, 7),
        demand_units = 55.0 + mod(idx, 15), lost_sales_units = mod(idx, 4) == 0 ? 5.0 : 0.0,
        source = "benchmark",
    ) for (idx, sku) in enumerate(fixture.skus)]
end

function _large_simulation_lanes(fixture::PerformanceBenchmarkFixture)::Vector{NamedTuple}
    return [(
        id = _large_benchmark_uuid(57, 1), tenant_id = fixture.tenant_id,
        from_warehouse_id = fixture.warehouses[1].id, to_warehouse_id = fixture.warehouses[2].id,
        lead_time_days = 2, cost_per_unit_cents = 25, capacity_units_day = 10_000.0, active = true,
    )]
end

function _large_simulation_store(fixture::PerformanceBenchmarkFixture)::MemoryTenantAdminStore
    tenant = (id = fixture.tenant_id, name = "Benchmark tenant", display_name = "Benchmark tenant", active = true)
    user = (id = UUID("40404040-0040-4040-8040-000000000001"), tenant_id = fixture.tenant_id, email = "benchmark@example.test", role = "admin", active = true)
    return MemoryTenantAdminStore(
        [tenant],
        [user];
        warehouses = _large_simulation_warehouses(fixture),
        skus = fixture.skus,
        inventory_positions = _large_simulation_inventory(fixture),
        demand_history = _large_simulation_demand(fixture),
        transfer_lanes = _large_simulation_lanes(fixture),
        allocation_policies = [_large_simulation_policy(fixture.tenant_id)],
    )
end

function benchmark_large_simulation(; iterations::Integer = _benchmark_iterations("BENCHMARK_SIMULATION_ITERATIONS", 1))::NamedTuple
    fixture = large_simulation_benchmark_fixture(; warehouse_count = 50, sku_count = 2_000, scenario_count = 100)
    policy = _large_simulation_policy(fixture.tenant_id)
    samples = Float64[]
    last_run = nothing
    last_scenario_count = 0
    last_recommendation_count = 0
    for iter in 1:Int(iterations)
        store = _large_simulation_store(fixture)
        ctx = _benchmark_context(fixture.tenant_id)
        elapsed = _elapsed_ms() do
            create_simulation_run!(store, ctx, Dict("policy_id" => string(policy.id), "name" => "Large benchmark simulation $(iter)", "scenario_count" => fixture.scenario_count))
            last_run = simulation_worker!(store, ctx; worker_id = "benchmark-large-simulation", seed = 53_000 + iter)
        end
        last_scenario_count = last_run === nothing ? 0 : length(last_run.scenarios)
        last_recommendation_count = length(store.allocation_recommendations)
        push!(samples, elapsed)
    end
    target = performance_targets().simulation_p95_ms
    measured_p95 = p95_ms(samples)
    return (
        fixture_warehouses = fixture.warehouse_count,
        fixture_skus = fixture.sku_count,
        fixture_scenarios = fixture.scenario_count,
        iterations = Int(iterations),
        samples_ms = samples,
        p95_ms = measured_p95,
        target_p95_ms = target,
        passed_target = measured_p95 <= target,
        final_status = last_run === nothing ? "not-run" : last_run.status,
        completed = last_run !== nothing && last_run.status == "completed",
        stored_scenarios = last_scenario_count,
        generated_recommendations = last_recommendation_count,
        measured_path = "create_simulation_run! plus simulation_worker! over 50 warehouses, 2,000 SKUs, and 100 generated demand scenarios",
    )
end
