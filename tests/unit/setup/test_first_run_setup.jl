using Test

mutable struct RecordingSetupStore <: InventoryAllocationSimulator.AbstractSetupStore
    tenant_count::Int
    tenants::Vector{NamedTuple}
    users::Vector{NamedTuple}
end

RecordingSetupStore(count::Int = 0) = RecordingSetupStore(count, NamedTuple[], NamedTuple[])

InventoryAllocationSimulator.count_tenants(store::RecordingSetupStore) = store.tenant_count
function InventoryAllocationSimulator.insert_tenant!(store::RecordingSetupStore, tenant)
    push!(store.tenants, tenant)
    store.tenant_count += 1
    return tenant.id
end
function InventoryAllocationSimulator.insert_admin_user!(store::RecordingSetupStore, user)
    push!(store.users, user)
    return user.id
end

function setup_test_config()
    InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/setup-test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
        "DEFAULT_TENANT_NAME" => "Default Ops",
        "DEFAULT_ADMIN_EMAIL" => "admin@example.com",
        "API_KEY_PREFIX" => "ias_test"
    ))
end

@testset "First-run setup creates tenant, admin, and one-time API key" begin
    store = RecordingSetupStore()
    result = InventoryAllocationSimulator.first_run_setup!(store, setup_test_config(); key_material = "deterministic-test-material")

    @test result.status == :created
    @test result.message == "First-run setup complete."
    @test startswith(result.api_key, "ias_test_")
    @test length(result.api_key_hash) == 64
    @test !occursin(result.api_key, result.api_key_hash)
    @test length(store.tenants) == 1
    @test store.tenants[1].name == "Default Ops"
    @test store.tenants[1].api_key_hash == result.api_key_hash
    @test length(store.users) == 1
    @test store.users[1].tenant_id == store.tenants[1].id
    @test store.users[1].email == "admin@example.com"
    @test store.users[1].role == "admin"
end

@testset "First-run setup is idempotent when a tenant already exists" begin
    store = RecordingSetupStore(1)
    result = InventoryAllocationSimulator.first_run_setup!(store, setup_test_config(); key_material = "deterministic-test-material")

    @test result.status == :already_initialized
    @test result.message == "Already initialized"
    @test result.api_key === nothing
    @test isempty(store.tenants)
    @test isempty(store.users)
end

@testset "First-run setup omits admin user when admin email is blank" begin
    env = Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/setup-test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
        "DEFAULT_TENANT_NAME" => "Default Ops",
        "DEFAULT_ADMIN_EMAIL" => "",
        "API_KEY_PREFIX" => "ias_test"
    )
    store = RecordingSetupStore()
    result = InventoryAllocationSimulator.first_run_setup!(store, InventoryAllocationSimulator.load_config(env); key_material = "deterministic-test-material")

    @test result.status == :created
    @test length(store.tenants) == 1
    @test isempty(store.users)
end
