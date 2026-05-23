using Test
using JSON3

@testset "Migration CLI validates direction before opening database" begin
    @test InventoryAllocationSimulator.run_migrate_cli(["--help"]) == 0
    @test InventoryAllocationSimulator.run_migrate_cli(["sideways"]) == 2
end

function migration_test_config(database_url::AbstractString)
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => database_url,
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/integration-health-test.duckdb",
        "SESSION_SECRET" => "development-session-secret",
        "METRICS_TOKEN" => "metrics-token-placeholder",
    ))
end

@testset "DB health response includes migration readiness state" begin
    config = migration_test_config(raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation")
    services = InventoryAllocationSimulator.build_services(config)
    response = InventoryAllocationSimulator.db_health_response(
        services;
        migration_dir = mktempdir(),
        migration_store = InventoryAllocationSimulator.MemoryMigrationStore(),
    )

    @test response.service == "postgresql"
    @test response.migrations.status == :current
    @test response.migrations.pending_versions == String[]
end

@testset "DB health response safely reports unreachable PostgreSQL without internals" begin
    config = migration_test_config("postgres://placeholder:placeholder@127.0.0.1:1/placeholder")
    services = InventoryAllocationSimulator.build_services(config)

    response = InventoryAllocationSimulator.db_health_response(services; migration_dir = mktempdir())

    @test response.status == "unavailable"
    @test response.service == "postgresql"
    @test response.error == "database_unavailable"
    serialized = JSON3.write(response)
    @test !occursin("Stacktrace", serialized)
    @test !occursin("PQConnectionError", serialized)
    @test !occursin("migrations.jl", serialized)
end
