using Test

const BATCH041_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch041_path(parts...) = joinpath(BATCH041_ROOT, parts...)
batch041_read(parts...) = read(batch041_path(parts...), String)

@testset "Batch 041 performance benchmarks cover solver timeout and outbox latency" begin
    targets = InventoryAllocationSimulator.performance_targets()
    @test haskey(targets, :solver_timeout_grace_seconds)
    @test targets.solver_timeout_grace_seconds == 10
    @test haskey(targets, :outbox_dispatch_p95_ms)
    @test targets.outbox_dispatch_p95_ms == 60 * 1000

    script = batch041_read("scripts", "benchmarks", "run_performance_benchmarks.jl")
    @test occursin("benchmark_solver_timeout", script)
    @test occursin("solver_timeout_grace_seconds", script)
    @test occursin("timeout_seconds + performance_targets().solver_timeout_grace_seconds", script)
    @test occursin("solve_allocation_model", script)
    @test occursin("AllocationSolverConfig", script)
    @test occursin("benchmark_outbox_dispatch_latency", script)
    @test occursin("queued_events", script)
    @test occursin("benchmark_outbox_dispatch_60s!", script)
    @test occursin("dispatch_outbox_once!", script)
    @test occursin("solver_timeout = solver_timeout", script)
    @test occursin("outbox_dispatch_latency = outbox_dispatch", script)
end

@testset "Batch 041 OpenAPI contract generation validates documented route definitions" begin
    script_path = batch041_path("scripts", "generate_openapi.jl")
    @test isfile(script_path)
    script = read(script_path, String)
    @test occursin("route_definitions", script)
    @test occursin("--check", script)
    @test occursin("YAML.write_file", script)
    @test occursin("validate_openapi_contract", script)

    spec = batch041_read("openapi.yaml")
    for path in [
        "/health/db",
        "/api/settings/tenant",
        "/api/users",
        "/api/recommendations/{id}",
        "/api/recommendations/{id}/approve",
        "/api/recommendations/{id}/reject",
        "/api/notifications/{id}/read",
        "/api/imports/{id}",
    ]
        @test occursin(path, spec)
    end
end

@testset "Batch 041 CI gates secrets and publishes GHCR images" begin
    ci = batch041_read(".github", "workflows", "ci.yml")
    @test occursin("bash scripts/scan-secrets.sh --mode tracked", ci)
    @test occursin("bash scripts/scan-secrets.sh --mode staged", ci)

    ghcr_path = batch041_path(".github", "workflows", "ghcr.yml")
    @test isfile(ghcr_path)
    ghcr = read(ghcr_path, String)
    @test occursin("ghcr.io", ghcr)
    @test occursin("docker/login-action", ghcr)
    @test occursin("docker/build-push-action", ghcr)
    @test occursin("packages: write", ghcr)
    @test occursin("push: true", ghcr)
    @test occursin("Dockerfile", ghcr)
end
