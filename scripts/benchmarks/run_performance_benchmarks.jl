#!/usr/bin/env julia

using Dates
using HTTP
using JSON3
using UUIDs
using InventoryAllocationSimulator

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

function _maybe_http_recommendation_probe()::NamedTuple
    base_url = strip(get(ENV, "BENCHMARK_BASE_URL", ""))
    api_key = strip(get(ENV, "BENCHMARK_API_KEY", ""))
    if isempty(base_url) || isempty(api_key)
        return (enabled = false, status = nothing, elapsed_ms = nothing, note = "set BENCHMARK_BASE_URL and BENCHMARK_API_KEY to additionally time live HTTP.request /api/recommendations")
    end
    elapsed = _elapsed_ms() do
        response = HTTP.request("GET", string(rstrip(base_url, '/'), "/api/recommendations?limit=250&status=proposed"), ["X-API-Key" => api_key])
        response.status == 200 || throw(ErrorException("live recommendation API benchmark returned HTTP $(response.status)"))
    end
    return (enabled = true, status = 200, elapsed_ms = elapsed, note = "live HTTP.request /api/recommendations completed")
end

function benchmark_recommendation_list_api(; iterations::Integer = _benchmark_iterations("BENCHMARK_RECOMMENDATION_ITERATIONS", 3))::NamedTuple
    store = _benchmark_store(; include_dimensions = false)
    ctx = _benchmark_context(first(values(store.tenants))[:id])
    params = Dict("limit" => "250", "status" => "proposed")
    warmup = list_recommendations(store, ctx; params = params)
    samples = Float64[]
    last_count = length(warmup.recommendations)
    for _ in 1:Int(iterations)
        elapsed = _elapsed_ms() do
            page = list_recommendations(store, ctx; params = params)
            last_count = length(page.recommendations)
        end
        push!(samples, elapsed)
    end
    target = performance_targets().recommendation_list_p95_ms
    return (
        endpoint = "/api/recommendations",
        fixture_recommendations = length(store.allocation_recommendations),
        page_size = last_count,
        iterations = Int(iterations),
        samples_ms = samples,
        p95_ms = p95_ms(samples),
        target_p95_ms = target,
        passed_target = p95_ms(samples) <= target,
        measured_path = "list_recommendations production API service path with authz, pagination, filtering, and view-model serialization",
        live_http = _maybe_http_recommendation_probe(),
    )
end

function benchmark_csv_import(; iterations::Integer = _benchmark_iterations("BENCHMARK_CSV_IMPORT_ITERATIONS", 1))::NamedTuple
    csv = csv_import_benchmark_fixture()
    fixture_rows = csv_import_benchmark_row_count(csv)
    samples = Float64[]
    last_result = nothing
    for _ in 1:Int(iterations)
        upload_dir = mktempdir(; prefix = "ias-benchmark-import-")
        try
            store = _benchmark_store(; include_dimensions = true)
            ctx = _benchmark_context(first(values(store.tenants))[:id])
            config = _benchmark_config(upload_dir)
            elapsed = _elapsed_ms() do
                job = create_import_job!(store, config, ctx, "inventory", "benchmark-inventory.csv", csv)
                last_result = process_import_job!(store, config, ctx, job.id)
            end
            push!(samples, elapsed)
        finally
            isdir(upload_dir) && rm(upload_dir; recursive = true, force = true)
        end
    end
    target = performance_targets().csv_import_p95_ms
    return (
        endpoint = "/api/imports",
        fixture_rows = fixture_rows,
        iterations = Int(iterations),
        samples_ms = samples,
        p95_ms = p95_ms(samples),
        target_p95_ms = target,
        passed_target = p95_ms(samples) <= target,
        committed_rows = last_result === nothing ? 0 : last_result.committed_rows,
        final_status = last_result === nothing ? "not-run" : last_result.status,
        measured_path = "create_import_job! plus process_import_job! production import validation, artifact persistence, worker commit, and result reporting path",
    )
end

function benchmark_manifest()::NamedTuple
    simulation = large_simulation_benchmark_fixture()
    recommendations = recommendation_list_benchmark_fixture()
    csv = csv_import_benchmark_fixture()
    rec_benchmark = benchmark_recommendation_list_api()
    csv_benchmark = benchmark_csv_import()
    return (
        schemaVersion = 1,
        source = "docs/inventory-allocation-simulator_prd.md §10b, §15",
        generated_at = string(Dates.now()),
        targets = performance_targets(),
        fixtures = (
            simulation = (
                warehouses = simulation.warehouse_count,
                skus = simulation.sku_count,
                scenarios = simulation.scenario_count,
                target_p95_ms = performance_targets().simulation_p95_ms,
            ),
            recommendation_list_api = (
                recommendations = length(recommendations),
                target_p95_ms = performance_targets().recommendation_list_p95_ms,
                endpoint = "/api/recommendations",
            ),
            csv_import = (
                rows = csv_import_benchmark_row_count(csv),
                target_p95_ms = performance_targets().csv_import_p95_ms,
                endpoint = "/api/imports",
            ),
            dashboard_lcp = (
                pages = dashboard_lcp_benchmark_pages(),
                target_lcp_ms = performance_targets().dashboard_lcp_ms,
            ),
        ),
        benchmarks = (
            recommendation_list_api = rec_benchmark,
            csv_import = csv_benchmark,
        ),
    )
end

function main()
    println(JSON3.write(benchmark_manifest()))
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
