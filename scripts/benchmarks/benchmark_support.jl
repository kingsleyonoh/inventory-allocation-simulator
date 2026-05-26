function _benchmark_iterations(key::AbstractString, default::Int)::Int
    parsed = tryparse(Int, get(ENV, key, string(default)))
    parsed === nothing && return default
    return max(parsed, 1)
end

function _elapsed_ms(work::Function)::Float64
    started = time_ns()
    work()
    return (time_ns() - started) / 1_000_000
end

function p95_ms(samples::AbstractVector{<:Real})::Float64
    isempty(samples) && throw(ArgumentError("p95 requires at least one timing sample"))
    ordered = sort(Float64.(samples))
    index = clamp(ceil(Int, 0.95 * length(ordered)), 1, length(ordered))
    return ordered[index]
end

function _benchmark_config(upload_storage_path::AbstractString)::InventoryAllocationSimulator.AppConfig
    return InventoryAllocationSimulator.AppConfig(
        InventoryAllocationSimulator.AppRuntimeConfig("benchmark", "127.0.0.1", 8000, "http://localhost:8000", "warn", false),
        InventoryAllocationSimulator.DatabaseConfig("postgres://localhost:5432/benchmark", "redis://localhost:6379/0", "./data/benchmark.duckdb"),
        InventoryAllocationSimulator.TenantConfig(false, "ias_bench", "Benchmark", "benchmark@example.test", "benchmark-session-secret"),
        InventoryAllocationSimulator.ImportConfig(64, true, String(upload_storage_path)),
        InventoryAllocationSimulator.SimulationConfig(100, 8, 180, 120, 0.05, 1, 30, 24, 7, true),
        InventoryAllocationSimulator.IntegrationConfig(false, "", "", false, "", "", "", false, "", "", ""),
        InventoryAllocationSimulator.ObservabilityConfig("", "benchmark-metrics-token", false, "", ""),
    )
end

function _benchmark_context(tenant_id::UUID)::TenantContext
    return TenantContext(tenant_id; user_id = UUID("40404040-0040-4040-8040-000000000001"), role = "admin", auth_method = :job)
end

function _benchmark_store(; include_dimensions::Bool = true)::MemoryTenantAdminStore
    fixture = large_simulation_benchmark_fixture()
    tenant = (id = fixture.tenant_id, name = "Benchmark tenant", display_name = "Benchmark tenant", active = true)
    user = (id = UUID("40404040-0040-4040-8040-000000000001"), tenant_id = fixture.tenant_id, email = "benchmark@example.test", role = "admin", active = true)
    recs = [(; row...) for row in recommendation_list_benchmark_fixture(; tenant_id = fixture.tenant_id)]
    return MemoryTenantAdminStore(
        [tenant],
        [user];
        warehouses = include_dimensions ? fixture.warehouses : [],
        skus = include_dimensions ? fixture.skus : [],
        demand_scenarios = fixture.demand_scenarios,
        allocation_recommendations = recs,
    )
end
