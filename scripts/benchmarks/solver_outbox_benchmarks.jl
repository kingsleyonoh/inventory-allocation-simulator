function _solver_timeout_snapshot()::NamedTuple
    tenant = "40404040-0040-4040-8040-404040404040"
    surplus = "10000000-0041-4000-8000-000000001001"
    need = "10000000-0041-4000-8000-000000001002"
    sku = "30000000-0041-4000-8000-000000001001"
    snapshot = _solver_timeout_snapshot_payload(tenant, surplus, need, sku)
    scenarios = [(
        id = "d0000000-0041-4000-8000-000000001001", tenant_id = tenant, simulation_run_id = "e0000000-0041-4000-8000-000000001001",
        scenario_index = 1, probability_weight = 1.0,
        demand_payload = Dict{String,Any}("demands" => [Dict{String,Any}("warehouse_id" => need, "sku_id" => sku, "demand_units" => 42.0, "baseline_units" => 42.0, "uncertainty_units" => 2.0, "stockout_periods" => 0)]),
    )]
    return (snapshot = snapshot, scenarios = scenarios)
end

function _solver_timeout_snapshot_payload(tenant::String, surplus::String, need::String, sku::String)::NamedTuple
    return (
        tenant_id = tenant,
        policy = (id = "b0000000-0041-4000-8000-000000001001", tenant_id = tenant, name = "Benchmark timeout policy", objective = "balanced", planning_horizon_days = 1, service_level_target = 0.95, max_transfer_cost_cents = nothing, allow_cross_region = true, frozen_until = nothing, config = Dict{String,Any}(), status = "active"),
        warehouses = [
            (id = surplus, tenant_id = tenant, code = "WH-SURPLUS", name = "Surplus", region = "North", capacity_units = 500.0, handling_cost_cents = 0, active = true),
            (id = need, tenant_id = tenant, code = "WH-NEED", name = "Need", region = "North", capacity_units = 500.0, handling_cost_cents = 0, active = true),
        ],
        skus = [(id = sku, tenant_id = tenant, sku_code = "SKU-FAST", name = "Fast SKU", category = "fast", unit_volume = 1.0, unit_margin_cents = 900, stockout_cost_cents = 1200, holding_cost_cents = 0, active = true)],
        inventory_positions = [
            (id = "50000000-0041-4000-8000-000000001001", tenant_id = tenant, warehouse_id = surplus, sku_id = sku, on_hand_units = 100.0, reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = 70.0, available_units = 100.0, as_of = "2026-05-26T00:00:00", source = "manual"),
            (id = "50000000-0041-4000-8000-000000001002", tenant_id = tenant, warehouse_id = need, sku_id = sku, on_hand_units = 10.0, reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = 20.0, available_units = 10.0, as_of = "2026-05-26T00:00:00", source = "manual"),
        ],
        transfer_lanes = [(id = "90000000-0041-4000-8000-000000001001", tenant_id = tenant, from_warehouse_id = surplus, to_warehouse_id = need, lead_time_days = 1, cost_per_unit_cents = 150, capacity_units_day = 200.0, active = true)],
    )
end

function benchmark_solver_timeout(; timeout_seconds::Real = _benchmark_iterations("BENCHMARK_SOLVER_TIMEOUT_SECONDS", 120), iterations::Integer = _benchmark_iterations("BENCHMARK_SOLVER_TIMEOUT_ITERATIONS", 1))::NamedTuple
    fixture = _solver_timeout_snapshot()
    budget_seconds = Float64(timeout_seconds) + performance_targets().solver_timeout_grace_seconds
    samples = Float64[]
    last_status = "not-run"
    for _ in 1:Int(iterations)
        elapsed = _elapsed_ms() do
            result = solve_allocation_model(fixture.snapshot, fixture.scenarios; config = AllocationSolverConfig(timeout_seconds = Float64(timeout_seconds), max_gap = 0.05, min_transfer_units = 1.0))
            last_status = result.status
        end
        push!(samples, elapsed)
    end
    return (
        configured_timeout_seconds = Float64(timeout_seconds),
        timeout_plus_grace_seconds = budget_seconds,
        iterations = Int(iterations),
        samples_ms = samples,
        p95_ms = p95_ms(samples),
        budget_ms = budget_seconds * 1000,
        passed_budget = p95_ms(samples) <= budget_seconds * 1000,
        final_status = last_status,
        measured_path = "solve_allocation_model with AllocationSolverConfig; wall-clock budget is timeout_seconds + performance_targets().solver_timeout_grace_seconds",
    )
end

function _outbox_benchmark_config()::InventoryAllocationSimulator.AppConfig
    return InventoryAllocationSimulator.AppConfig(
        InventoryAllocationSimulator.AppRuntimeConfig("benchmark", "127.0.0.1", 8000, "http://localhost:8000", "warn", false),
        InventoryAllocationSimulator.DatabaseConfig("postgres://localhost:5432/benchmark", "redis://localhost:6379/0", "./data/benchmark.duckdb"),
        InventoryAllocationSimulator.TenantConfig(false, "ias_bench", "Benchmark", "benchmark@example.test", "benchmark-session-secret"),
        InventoryAllocationSimulator.ImportConfig(64, true, "./data/uploads"),
        InventoryAllocationSimulator.SimulationConfig(100, 8, 180, 120, 0.05, 1, 30, 24, 7, true),
        InventoryAllocationSimulator.IntegrationConfig(true, "http://notification-hub.local", "placeholder", false, "", "", "", false, "", "", ""),
        InventoryAllocationSimulator.ObservabilityConfig("", "benchmark-metrics-token", false, "", ""),
    )
end

function _outbox_benchmark_store(; queued_events::Integer = 100)::MemoryTenantAdminStore
    fixture = large_simulation_benchmark_fixture()
    tenant = (id = fixture.tenant_id, name = "Benchmark tenant", display_name = "Benchmark tenant", active = true)
    user = (id = UUID("40404040-0041-4040-8041-000000000001"), tenant_id = fixture.tenant_id, email = "benchmark@example.test", role = "admin", active = true)
    now = DateTime(2026, 5, 26)
    event_count = queued_events > 0 ? Int(queued_events) : throw(ArgumentError("queued_events must be positive"))
    outbox = [_outbox_benchmark_row(fixture.tenant_id, idx, now) for idx in 1:event_count]
    return MemoryTenantAdminStore([tenant], [user]; ecosystem_outbox = outbox)
end

function _outbox_benchmark_row(tenant_id::UUID, idx::Integer, now::DateTime)::NamedTuple
    return (
        id = uuid4(), tenant_id = tenant_id, event_type = "simulation.completed", event_id = "benchmark-outbox-$(idx)",
        payload = Dict{String,Any}("event_type" => "simulation.completed", "event_id" => "benchmark-outbox-$(idx)", "tenant_id" => string(tenant_id), "payload" => Dict{String,Any}("tenant" => Dict{String,Any}("display_name" => "Benchmark tenant", "contact" => Dict{String,Any}("email" => "benchmark@example.test")))),
        target = "notification_hub", status = "queued", attempts = 0, next_attempt_at = now,
        last_error = nothing, created_at = now + Millisecond(idx), updated_at = now + Millisecond(idx),
    )
end

function benchmark_outbox_dispatch_latency(; queued_events::Integer = _benchmark_iterations("BENCHMARK_OUTBOX_EVENTS", 100), iterations::Integer = _benchmark_iterations("BENCHMARK_OUTBOX_ITERATIONS", 1))::NamedTuple
    samples = Float64[]
    last_result = nothing
    for _ in 1:Int(iterations)
        store = _outbox_benchmark_store(; queued_events = queued_events)
        config = _outbox_benchmark_config()
        elapsed = _elapsed_ms() do
            last_result = benchmark_outbox_dispatch_60s!(store, config; now = DateTime(2026, 5, 26), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 202, body = "accepted"))
            dispatch_outbox_once!(store, config; now = DateTime(2026, 5, 26), http_post = (url, body, headers; timeout_seconds = 10) -> (status = 202, body = "accepted"))
        end
        push!(samples, elapsed)
    end
    target = performance_targets().outbox_dispatch_p95_ms
    return (
        queued_events = Int(queued_events), iterations = Int(iterations), samples_ms = samples,
        p95_ms = p95_ms(samples), target_p95_ms = target, passed_target = p95_ms(samples) <= target,
        sent = last_result === nothing ? 0 : last_result.sent,
        within_60_seconds = last_result === nothing ? false : last_result.within_60_seconds,
        measured_path = "benchmark_outbox_dispatch_60s! and dispatch_outbox_once! over queued ecosystem_outbox events",
    )
end
