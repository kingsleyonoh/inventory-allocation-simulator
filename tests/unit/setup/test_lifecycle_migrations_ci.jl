using Test

const SETUP_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
setup_readroot(path...) = read(joinpath(SETUP_ROOT, path...), String)
setup_existsroot(path...) = ispath(joinpath(SETUP_ROOT, path...))

function setup_test_config_for_lifecycle()
    InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/lifecycle-test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
        "APP_PORT" => "8011",
    ))
end

@testset "Graceful shutdown closes services in dependency-safe order" begin
    config = setup_test_config_for_lifecycle()
    services = InventoryAllocationSimulator.build_services(config)

    @test services.jobs.running == false
    InventoryAllocationSimulator.start!(services.jobs)
    @test services.jobs.running == true

    InventoryAllocationSimulator.shutdown!(services; stop_http = false)

    @test services.jobs.running == false
    @test services.jobs.shutdown_requested == true
    @test services.db.connection === nothing
end

@testset "Migration runner discovers ordered up/down files and reports readiness" begin
    mktempdir() do dir
        write(joinpath(dir, "002_add_users.up.sql"), "CREATE TABLE users (id INT);\n")
        write(joinpath(dir, "001_add_tenants.up.sql"), "CREATE TABLE tenants (id INT);\n")
        write(joinpath(dir, "001_add_tenants.down.sql"), "DROP TABLE tenants;\n")
        write(joinpath(dir, "002_add_users.down.sql"), "DROP TABLE users;\n")

        migrations = InventoryAllocationSimulator.discover_migrations(dir)
        @test [migration.version for migration in migrations] == ["001", "002"]
        @test [migration.name for migration in migrations] == ["add_tenants", "add_users"]

        store = InventoryAllocationSimulator.MemoryMigrationStore()
        health_before = InventoryAllocationSimulator.migration_health(store, dir)
        @test health_before.status == :pending
        @test health_before.pending_versions == ["001", "002"]

        up_result = InventoryAllocationSimulator.run_migrations!(store, dir; direction = :up)
        @test up_result.direction == :up
        @test up_result.applied_versions == ["001", "002"]
        @test store.executed_sql == ["CREATE TABLE tenants (id INT);\n", "CREATE TABLE users (id INT);\n"]
        @test InventoryAllocationSimulator.migration_health(store, dir).status == :current

        down_result = InventoryAllocationSimulator.run_migrations!(store, dir; direction = :down)
        @test down_result.direction == :down
        @test down_result.applied_versions == ["002", "001"]
        @test store.executed_sql[end-1:end] == ["DROP TABLE users;\n", "DROP TABLE tenants;\n"]
    end
end

@testset "Setup and CI files expose production deployment and quality gates" begin
    dockerfile = setup_readroot("Dockerfile")
    compose = setup_readroot("docker-compose.yml")
    workflow = setup_readroot(".github", "workflows", "ci.yml")

    @test occursin("julia:1.11", dockerfile)
    @test occursin("scripts/migrate.jl up", dockerfile)
    @test occursin("src/Main.jl", dockerfile)
    @test !occursin("COPY . .", dockerfile)

    @test occursin("app:", compose)
    @test occursin("build:", compose)
    @test occursin("condition: service_healthy", compose)
    @test occursin("julia --project scripts/migrate.jl up", compose)

    for token in [
        "workflow_dispatch:",
        "julia --project -e 'using Pkg; Pkg.test()'",
        "Aqua.test_all(InventoryAllocationSimulator; stale_deps=false)",
        "julia --project scripts/migrate.jl up",
        "npx playwright test",
        "bash scripts/scan-secrets.sh --mode tracked",
    ]
        @test occursin(token, workflow)
    end
end

@testset "Production image context excludes internal automation artifacts" begin
    dockerignore_lines = Set(strip.(split(setup_readroot(".dockerignore"), '\n')))
    @test ".agent" in dockerignore_lines
    @test ".yolo" in dockerignore_lines
    @test !("!.yolo/batch-results" in dockerignore_lines)
    @test !("!.yolo/gates" in dockerignore_lines)
end

@testset "Julia test infrastructure supports unit and integration tiers" begin
    runner = setup_readroot("tests", "runtests.jl")
    @test occursin("include_tree", runner)
    @test occursin("unit", runner)
    @test occursin("integration", runner)
    @test setup_existsroot("tests", "unit")
    @test setup_existsroot("tests", "integration")
    @test setup_existsroot("tests", "fixtures")
end
