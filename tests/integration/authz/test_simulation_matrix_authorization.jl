using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

const SIM_MATRIX_TENANT = UUID("22222222-2222-4222-8222-222222222222")
const SIM_MATRIX_POLICY = UUID("22222222-0000-4000-8000-000000000001")
const SIM_MATRIX_WAREHOUSE_A = UUID("22222222-1000-4000-8000-000000000001")
const SIM_MATRIX_WAREHOUSE_B = UUID("22222222-1000-4000-8000-000000000002")
const SIM_MATRIX_SKU = UUID("22222222-3000-4000-8000-000000000001")

function sim_matrix_ctx(role::AbstractString)::TenantContext
    user_id = role == "admin" ? UUID("aaaaaaaa-2222-4222-8222-222222222222") :
              role == "planner" ? UUID("bbbbbbbb-2222-4222-8222-222222222222") :
              UUID("cccccccc-2222-4222-8222-222222222222")
    return TenantContext(SIM_MATRIX_TENANT; user_id = user_id, role = String(role), auth_method = :session)
end

function sim_matrix_tenants()
    return [(
        id = SIM_MATRIX_TENANT, name = "Simulation Matrix Tenant", legal_name = "Simulation Matrix Ltd",
        full_legal_name = "Simulation Matrix Limited", display_name = "Simulation Matrix",
        address = Dict("city" => "Bristol"), registration = Dict("company_number" => "SIM-MATRIX"),
        contact = Dict("email" => "sim-matrix@example.test"), wordmark = nothing,
        api_key_hash = hash_api_key("ias_test_sim_matrix"), is_active = true,
    )]
end

function sim_matrix_users()
    return [
        (id = sim_matrix_ctx("admin").user_id, tenant_id = SIM_MATRIX_TENANT, email = "admin@sim-matrix.example.test", name = "Matrix Admin", role = "admin", is_active = true),
        (id = sim_matrix_ctx("planner").user_id, tenant_id = SIM_MATRIX_TENANT, email = "planner@sim-matrix.example.test", name = "Matrix Planner", role = "planner", is_active = true),
        (id = sim_matrix_ctx("viewer").user_id, tenant_id = SIM_MATRIX_TENANT, email = "viewer@sim-matrix.example.test", name = "Matrix Viewer", role = "viewer", is_active = true),
    ]
end

function sim_matrix_warehouses()
    return [
        (id = SIM_MATRIX_WAREHOUSE_A, tenant_id = SIM_MATRIX_TENANT, code = "A", name = "Warehouse A", region = "GB-SW", latitude = nothing, longitude = nothing, capacity_units = 1000.0, handling_cost_cents = 10, active = true),
        (id = SIM_MATRIX_WAREHOUSE_B, tenant_id = SIM_MATRIX_TENANT, code = "B", name = "Warehouse B", region = "GB-SW", latitude = nothing, longitude = nothing, capacity_units = 1000.0, handling_cost_cents = 10, active = true),
    ]
end

function sim_matrix_skus()
    return [(
        id = SIM_MATRIX_SKU, tenant_id = SIM_MATRIX_TENANT, sku_code = "SKU-MATRIX", name = "Matrix SKU",
        category = "matrix", unit_volume = 1.0, unit_margin_cents = 500, stockout_cost_cents = 1000,
        holding_cost_cents = 25, active = true,
    )]
end

function sim_matrix_inventory()
    return [(
        id = UUID("22222222-5000-4000-8000-000000000001"), tenant_id = SIM_MATRIX_TENANT,
        warehouse_id = SIM_MATRIX_WAREHOUSE_A, sku_id = SIM_MATRIX_SKU, on_hand_units = 100.0,
        reserved_units = 0.0, inbound_units = 0.0, safety_stock_units = 10.0,
        as_of = DateTime(2026, 5, 24, 9), source = "manual",
    )]
end

function sim_matrix_demand()
    return [(
        id = UUID("22222222-7000-4000-8000-000000000001"), tenant_id = SIM_MATRIX_TENANT,
        warehouse_id = SIM_MATRIX_WAREHOUSE_A, sku_id = SIM_MATRIX_SKU, period_start = Date(2026, 5, 1),
        period_end = Date(2026, 5, 7), demand_units = 25.0, lost_sales_units = 0.0, source = "manual",
    )]
end

function sim_matrix_lanes()
    return [(
        id = UUID("22222222-9000-4000-8000-000000000001"), tenant_id = SIM_MATRIX_TENANT,
        from_warehouse_id = SIM_MATRIX_WAREHOUSE_A, to_warehouse_id = SIM_MATRIX_WAREHOUSE_B,
        lead_time_days = 2, cost_per_unit_cents = 100, capacity_units_day = 50.0, active = true,
    )]
end

function sim_matrix_policies()
    return [(
        id = SIM_MATRIX_POLICY, tenant_id = SIM_MATRIX_TENANT, name = "Simulation matrix policy",
        objective = "balanced", planning_horizon_days = 30, service_level_target = 0.95,
        max_transfer_cost_cents = nothing, allow_cross_region = true, frozen_until = nothing,
        config = Dict{String,Any}(), status = "active",
    )]
end

function sim_matrix_store()::MemoryTenantAdminStore
    return MemoryTenantAdminStore(
        sim_matrix_tenants(),
        sim_matrix_users();
        warehouses = sim_matrix_warehouses(),
        skus = sim_matrix_skus(),
        inventory_positions = sim_matrix_inventory(),
        demand_history = sim_matrix_demand(),
        transfer_lanes = sim_matrix_lanes(),
        allocation_policies = sim_matrix_policies(),
    )
end

function sim_matrix_allowed(path::AbstractString)::Dict{String,Bool}
    matrix = JSON3.read(read(path, String))
    return Dict(String(policy.key) => Bool(policy.allowed) for policy in matrix.policies if String(policy.resource) == "simulation" && String(policy.action) == "run_cancel")
end

@testset "Integration authz matrix covers simulation run/cancel role cells" begin
    root = project_root()
    fixture_allowed = sim_matrix_allowed(joinpath(root, "tests", "fixtures", "authz_matrix.json"))
    runtime_allowed = sim_matrix_allowed(joinpath(root, "config", "authz_matrix.json"))
    expected = Dict(
        "admin:simulation:run_cancel" => true,
        "planner:simulation:run_cancel" => true,
        "viewer:simulation:run_cancel" => false,
    )
    @test fixture_allowed == expected
    @test runtime_allowed == expected

    for role in ("admin", "planner")
        store = sim_matrix_store()
        ctx = sim_matrix_ctx(role)
        run = create_simulation_run!(store, ctx, Dict("policy_id" => string(SIM_MATRIX_POLICY), "name" => "$(role) simulation", "scenario_count" => 1))
        @test run.status == "queued"
        cancelled = cancel_simulation_run!(store, ctx, run.id)
        @test cancelled.status == "cancelled"
    end

    denied_store = sim_matrix_store()
    viewer = sim_matrix_ctx("viewer")
    admin_run = create_simulation_run!(denied_store, sim_matrix_ctx("admin"), Dict("policy_id" => string(SIM_MATRIX_POLICY), "name" => "viewer denial target", "scenario_count" => 1))
    @test_throws AuthzError create_simulation_run!(denied_store, viewer, Dict("policy_id" => string(SIM_MATRIX_POLICY), "name" => "viewer denied", "scenario_count" => 1))
    @test_throws AuthzError cancel_simulation_run!(denied_store, viewer, admin_run.id)
end
