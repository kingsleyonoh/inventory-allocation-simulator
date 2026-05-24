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
    return MemoryTenantAdminStore(tenants, users; warehouses = warehouses, skus = skus)
end
