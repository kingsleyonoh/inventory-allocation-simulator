using Dates
using UUIDs
using InventoryAllocationSimulator

const BATCH012_TENANT_A = UUID("12121212-1212-4121-8121-121212121212")
const BATCH012_TENANT_B = UUID("34343434-3434-4343-8343-343434343434")
const BATCH012_ADMIN_A = TenantContext(BATCH012_TENANT_A; user_id = UUID("aaaaaaaa-1212-4121-8121-121212121212"), role = "admin", auth_method = :session)
const BATCH012_PLANNER_A = TenantContext(BATCH012_TENANT_A; user_id = UUID("bbbbbbbb-1212-4121-8121-121212121212"), role = "planner", auth_method = :session)
const BATCH012_VIEWER_A = TenantContext(BATCH012_TENANT_A; user_id = UUID("cccccccc-1212-4121-8121-121212121212"), role = "viewer", auth_method = :session)
const BATCH012_ADMIN_B = TenantContext(BATCH012_TENANT_B; user_id = UUID("dddddddd-3434-4343-8343-343434343434"), role = "admin", auth_method = :session)

function batch012_config()
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch012.duckdb",
        "SESSION_SECRET" => "batch012-session-secret-placeholder",
        "METRICS_TOKEN" => "batch012-metrics-token-placeholder",
        "SELF_REGISTRATION_ENABLED" => "true",
        "API_KEY_PREFIX" => "ias_test",
        "DEFAULT_ADMIN_EMAIL" => "admin@example.test",
    ))
end

function batch012_store()
    tenants = [
        (
            id = BATCH012_TENANT_A, name = "Northstar Demo", legal_name = "Northstar Supply Ltd",
            full_legal_name = "Northstar Supply Limited", display_name = "Northstar Supply",
            address = Dict("city" => "Bristol"), registration = Dict("company_number" => "NS-012"),
            contact = Dict("email" => "ops+northstar@example.test"), wordmark = nothing,
            api_key_hash = hash_api_key("ias_test_northstar"), is_active = true,
        ),
        (
            id = BATCH012_TENANT_B, name = "Kōwhai Logistics", legal_name = "Kōwhai Logistics NZ Limited",
            full_legal_name = "Kōwhai Logistics New Zealand Limited", display_name = "Kōwhai Logistics",
            address = Dict("city" => "Wellington"), registration = Dict("company_number" => "NZBN-012"),
            contact = Dict("email" => "planning+kowhai@example.test"), wordmark = nothing,
            api_key_hash = hash_api_key("ias_test_kowhai"), is_active = true,
        ),
    ]
    users = [
        (id = BATCH012_ADMIN_A.user_id, tenant_id = BATCH012_TENANT_A, email = "admin@northstar.example.test", name = "Northstar Admin", role = "admin", is_active = true),
        (id = BATCH012_PLANNER_A.user_id, tenant_id = BATCH012_TENANT_A, email = "planner@northstar.example.test", name = "Northstar Planner", role = "planner", is_active = true),
        (id = BATCH012_ADMIN_B.user_id, tenant_id = BATCH012_TENANT_B, email = "admin@kowhai.example.test", name = "Kōwhai Admin", role = "admin", is_active = true),
    ]
    warehouses = [
        (id = UUID("10000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_A, code = "BRI", name = "Bristol DC", region = "GB-SW", latitude = 51.4545, longitude = -2.5879, capacity_units = 10000.0, handling_cost_cents = 15, active = true),
        (id = UUID("10000000-0000-4000-8000-000000000002"), tenant_id = BATCH012_TENANT_A, code = "EDI", name = "Edinburgh DC", region = "GB-SCT", latitude = nothing, longitude = nothing, capacity_units = 7000.0, handling_cost_cents = 10, active = false),
        (id = UUID("20000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_B, code = "WLG", name = "Wellington DC", region = "NZ-WGN", latitude = -41.2865, longitude = 174.7762, capacity_units = 5000.0, handling_cost_cents = 12, active = true),
    ]
    skus = [
        (id = UUID("30000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_A, sku_code = "SKU-RED", name = "Red Widget", category = "widgets", unit_volume = 1.25, unit_margin_cents = 550, stockout_cost_cents = 900, holding_cost_cents = 25, active = true),
        (id = UUID("30000000-0000-4000-8000-000000000002"), tenant_id = BATCH012_TENANT_A, sku_code = "SKU-BLUE", name = "Blue Widget", category = "widgets", unit_volume = 2.0, unit_margin_cents = 450, stockout_cost_cents = 800, holding_cost_cents = 20, active = false),
        (id = UUID("40000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_B, sku_code = "SKU-KIWI", name = "Kōwhai Pack", category = "packs", unit_volume = 3.0, unit_margin_cents = 750, stockout_cost_cents = 1200, holding_cost_cents = 35, active = true),
    ]
    inventory_positions = [
        (id = UUID("50000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_A, warehouse_id = warehouses[1].id, sku_id = skus[1].id, on_hand_units = 100.0, reserved_units = 10.0, inbound_units = 25.0, safety_stock_units = 30.0, as_of = DateTime(2026, 5, 1, 9), source = "manual"),
        (id = UUID("50000000-0000-4000-8000-000000000002"), tenant_id = BATCH012_TENANT_A, warehouse_id = warehouses[2].id, sku_id = skus[2].id, on_hand_units = 4.0, reserved_units = 1.0, inbound_units = 0.0, safety_stock_units = 12.0, as_of = DateTime(2026, 5, 1, 9), source = "csv"),
        (id = UUID("60000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_B, warehouse_id = warehouses[3].id, sku_id = skus[3].id, on_hand_units = 500.0, reserved_units = 0.0, inbound_units = 20.0, safety_stock_units = 40.0, as_of = DateTime(2026, 5, 1, 9), source = "api"),
    ]
    demand_history = [
        (id = UUID("70000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_A, warehouse_id = warehouses[1].id, sku_id = skus[1].id, period_start = Date(2026, 4, 1), period_end = Date(2026, 4, 7), demand_units = 80.0, lost_sales_units = 15.0, source = "manual"),
        (id = UUID("70000000-0000-4000-8000-000000000002"), tenant_id = BATCH012_TENANT_A, warehouse_id = warehouses[2].id, sku_id = skus[2].id, period_start = Date(2026, 4, 8), period_end = Date(2026, 4, 14), demand_units = 8.0, lost_sales_units = 0.0, source = "csv"),
        (id = UUID("80000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_B, warehouse_id = warehouses[3].id, sku_id = skus[3].id, period_start = Date(2026, 4, 1), period_end = Date(2026, 4, 7), demand_units = 300.0, lost_sales_units = 5.0, source = "api"),
    ]
    transfer_lanes = [
        (id = UUID("90000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_A, from_warehouse_id = warehouses[1].id, to_warehouse_id = warehouses[2].id, lead_time_days = 2, cost_per_unit_cents = 125, capacity_units_day = 200.0, active = true),
        (id = UUID("90000000-0000-4000-8000-000000000002"), tenant_id = BATCH012_TENANT_A, from_warehouse_id = warehouses[2].id, to_warehouse_id = warehouses[1].id, lead_time_days = 3, cost_per_unit_cents = 140, capacity_units_day = nothing, active = false),
        (id = UUID("a0000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_B, from_warehouse_id = warehouses[3].id, to_warehouse_id = warehouses[3].id, lead_time_days = 0, cost_per_unit_cents = 0, capacity_units_day = 50.0, active = true),
    ]
    allocation_policies = [
        (id = UUID("b0000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_A, name = "Balanced baseline", objective = "balanced", planning_horizon_days = 30, service_level_target = 0.95, max_transfer_cost_cents = 50_000, allow_cross_region = true, frozen_until = nothing, config = Dict("priority" => "service"), status = "active"),
        (id = UUID("b0000000-0000-4000-8000-000000000002"), tenant_id = BATCH012_TENANT_A, name = "Draft margin", objective = "maximize_margin", planning_horizon_days = 45, service_level_target = 0.9, max_transfer_cost_cents = nothing, allow_cross_region = false, frozen_until = Date(2026, 6, 1), config = Dict{String,Any}(), status = "draft"),
        (id = UUID("c0000000-0000-4000-8000-000000000001"), tenant_id = BATCH012_TENANT_B, name = "Kōwhai active", objective = "minimize_total_cost", planning_horizon_days = 21, service_level_target = 0.93, max_transfer_cost_cents = 10_000, allow_cross_region = true, frozen_until = nothing, config = Dict{String,Any}(), status = "active"),
    ]
    return MemoryTenantAdminStore(
        tenants,
        users;
        warehouses = warehouses,
        skus = skus,
        inventory_positions = inventory_positions,
        demand_history = demand_history,
        transfer_lanes = transfer_lanes,
        allocation_policies = allocation_policies,
    )
end
