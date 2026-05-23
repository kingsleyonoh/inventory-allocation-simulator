using Test
using TOML

const ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
readroot(path...) = read(joinpath(ROOT, path...), String)
existsroot(path...) = ispath(joinpath(ROOT, path...))

@testset "Julia package and dependency manifest" begin
    project_path = joinpath(ROOT, "Project.toml")
    @test isfile(project_path)
    project = TOML.parsefile(project_path)
    @test project["name"] == "InventoryAllocationSimulator"
    @test haskey(project, "deps")
    for dep in ["Genie", "HTTP", "LibPQ", "Redis", "DuckDB", "JuMP", "HiGHS", "StatsBase", "Distributions", "JSON3"]
        @test haskey(project["deps"], dep)
    end
end

@testset "Project scaffold matches PRD section 9" begin
    for path in [
        "src/InventoryAllocationSimulator.jl", "src/Main.jl", "config/routes.jl", "migrations", "scripts",
        "src/db", "src/tenant", "src/imports", "src/planning", "src/solver",
        "src/recommendations", "src/notifications", "src/jobs", "src/integrations",
        "src/events", "src/web/controllers", "src/web/views", "src/web/components",
        "src/observability", "openapi.yaml"
    ]
        @test existsroot(split(path, '/')...)
    end

    package_entry = readroot("src", "InventoryAllocationSimulator.jl")
    @test occursin("module InventoryAllocationSimulator", package_entry)
    @test occursin("function run_server!", package_entry)
    @test occursin("include(\"../config/routes.jl\")", package_entry)

    main = readroot("src", "Main.jl")
    @test occursin("InventoryAllocationSimulator.main()", main)

    routes = readroot("config", "routes.jl")
    @test occursin("register_routes!", routes)
    @test occursin("/health", routes)
end

@testset "Local infrastructure and safe storage defaults" begin
    compose = readroot("docker-compose.yml")
    @test occursin("postgres:16", compose)
    @test occursin("redis:7", compose)
    @test occursin("healthcheck:", compose)
    @test occursin("pg_isready", compose)
    @test occursin("redis-cli ping", compose)
    @test occursin(raw"${POSTGRES_PASSWORD", compose)

    env = readroot(".env.example")
    @test occursin("POSTGRES_PASSWORD=your-password-here", env)
    @test occursin("DATABASE_URL=postgres://", env)
    @test occursin("REDIS_URL=redis://localhost:6379/0", env)
    @test occursin("DUCKDB_PATH=./data/backtests.duckdb", env)
    @test occursin("UPLOAD_STORAGE_PATH=./data/uploads", env)
    @test occursin("SESSION_SECRET=your-session-secret-here", env)
    @test !occursin("SESSION_SECRET=xxxxx", env)

    @test isdir(joinpath(ROOT, "data"))
    @test isdir(joinpath(ROOT, "data", "uploads"))
end
