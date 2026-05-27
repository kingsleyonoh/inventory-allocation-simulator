using Test

const BATCH058_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch058_path(parts...) = joinpath(BATCH058_ROOT, parts...)
batch058_read(parts...) = read(batch058_path(parts...), String)

@testset "Batch 058 E2E real HTTP PostgreSQL Redis audit contract" begin
    progress = batch058_read("docs", "progress.md")
    @test occursin("- [x] [AUDIT] Verify E2E tests hit real HTTP with PostgreSQL and Redis — PRD §15", progress)

    config = batch058_read("playwright.config.js")
    @test occursin("webServer", config)
    @test occursin("node tests/e2e/helpers/start_webserver.js", config)
    @test occursin("baseURL", config)
    @test occursin("DATABASE_URL", config)
    @test occursin("REDIS_URL", config)
    @test occursin("/health", config)

    starter = batch058_read("tests", "e2e", "helpers", "start_webserver.js")
    @test occursin("docker", starter)
    @test occursin("compose", starter)
    @test occursin("--wait", starter)
    @test occursin("postgres", starter)
    @test occursin("redis", starter)
    @test occursin("julia", starter)
    @test occursin("--project", starter)
    @test occursin("src/Main.jl", starter)
    @test occursin("DATABASE_URL", starter)

    stack_spec = batch058_read("tests", "e2e", "postgres-redis-stack.spec.js")
    @test occursin("request.get('/health/db')", stack_spec)
    @test occursin("request.get('/health/ready')", stack_spec)
    @test occursin("service).toBe('postgresql')", stack_spec)
    @test occursin("docker", stack_spec)
    @test occursin("compose", stack_spec)
    @test occursin("toContain('postgres')", stack_spec)
    @test occursin("toContain('redis')", stack_spec)

    health_spec = batch058_read("tests", "e2e", "health.spec.js")
    @test occursin("request.get('/health')", health_spec)
    @test occursin("404", health_spec)

    gate_script = batch058_path(".yolo", "scripts", "validate-batch-058-e2e-real-stack.sh")
    @test isfile(gate_script)
    if isfile(gate_script)
        @test success(`bash $gate_script`)
    end
end
