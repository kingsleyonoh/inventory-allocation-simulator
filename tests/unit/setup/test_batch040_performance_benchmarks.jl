using Test
using JSON3

const BATCH040_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch040_path(parts...) = joinpath(BATCH040_ROOT, parts...)
batch040_read(parts...) = read(batch040_path(parts...), String)

@testset "Batch 040 performance benchmark fixtures encode PRD 10b targets" begin
    targets = InventoryAllocationSimulator.performance_targets()
    @test targets.simulation_p95_ms == 10 * 60 * 1000
    @test targets.recommendation_list_p95_ms == 250
    @test targets.csv_import_p95_ms == 3 * 60 * 1000
    @test targets.dashboard_lcp_ms == 2500

    fixture = InventoryAllocationSimulator.large_simulation_benchmark_fixture()
    @test fixture.warehouse_count == 50
    @test fixture.sku_count == 2000
    @test fixture.scenario_count == 100
    @test length(fixture.warehouses) == 50
    @test length(fixture.skus) == 2000
    @test length(fixture.demand_scenarios) == 100
    @test first(fixture.warehouses).tenant_id == fixture.tenant_id
    @test first(fixture.skus).tenant_id == fixture.tenant_id

    recs = InventoryAllocationSimulator.recommendation_list_benchmark_fixture()
    @test length(recs) == 10_000
    @test all(row -> row[:tenant_id] == first(recs)[:tenant_id], recs)
    @test all(row -> row[:status] == "proposed", recs)

    csv = InventoryAllocationSimulator.csv_import_benchmark_fixture()
    @test InventoryAllocationSimulator.csv_import_benchmark_row_count(csv) == 100_000
    @test startswith(csv, "warehouse_code,sku_code,on_hand_units")

    pages = InventoryAllocationSimulator.dashboard_lcp_benchmark_pages()
    @test "/dashboard" in pages
    @test "/imports" in pages
    @test "/simulations" in pages

    @test_throws ArgumentError InventoryAllocationSimulator.large_simulation_benchmark_fixture(; warehouse_count = 0)
    @test_throws ArgumentError InventoryAllocationSimulator.recommendation_list_benchmark_fixture(; count = 0)
    @test_throws ArgumentError InventoryAllocationSimulator.csv_import_benchmark_fixture(; row_count = 0)
end

@testset "Batch 040 benchmark runner and E2E stack specs are wired" begin
    script = batch040_read("scripts", "benchmarks", "run_performance_benchmarks.jl")
    @test occursin("large_simulation_benchmark_fixture", script)
    @test occursin("recommendation_list_benchmark_fixture", script)
    @test occursin("csv_import_benchmark_fixture", script)
    @test occursin("dashboard_lcp_benchmark_pages", script)
    @test occursin("JSON3.write", script)
    @test occursin("p95_ms", script)
    @test occursin("time_ns", script)
    @test occursin("list_recommendations", script)
    @test occursin("create_import_job!", script)
    @test occursin("process_import_job!", script)
    @test occursin("HTTP.request", script)
    @test occursin("simulation_benchmarks.jl", script)
    @test occursin("benchmark_large_simulation", script)

    simulation_benchmark = batch040_read("scripts", "benchmarks", "simulation_benchmarks.jl")
    @test occursin("large_simulation_benchmark_fixture", simulation_benchmark)
    @test occursin("create_simulation_run!", simulation_benchmark)
    @test occursin("simulation_worker!", simulation_benchmark)
    @test occursin("scenario_count = 100", simulation_benchmark)
    @test occursin("performance_targets().simulation_p95_ms", simulation_benchmark)
    @test occursin("passed_target", simulation_benchmark)

    manifest = batch040_read("scripts", "benchmarks", "benchmark_manifest.jl")
    @test occursin("large_simulation = benchmark_large_simulation()", manifest)
    @test occursin("large_simulation = large_simulation", manifest)

    e2e = batch040_read("tests", "e2e", "postgres-redis-stack.spec.js")
    @test occursin("/health/db", e2e)
    @test occursin("/health/ready", e2e)
    @test occursin("docker", e2e)
    @test occursin("postgres", e2e)
    @test occursin("redis", e2e)

    lcp = batch040_read("tests", "e2e", "dashboard-lcp-benchmark.spec.js")
    @test occursin("largest-contentful-paint", lcp)
    @test occursin("/dashboard", lcp)
    @test occursin("2500", lcp)
end
