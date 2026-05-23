using Test

const SECURITY_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
security_readroot(path...) = read(joinpath(SECURITY_ROOT, path...), String)

@testset "First-run security contracts" begin
    bootstrap_source = security_readroot("src", "tenant", "bootstrap.jl")
    prd_source = security_readroot("docs", "inventory-allocation-simulator_prd.md")

    @test occursin("RandomDevice", bootstrap_source)
    direct_default_rng_pattern = "rand(" * "UInt8"
    @test !occursin(direct_default_rng_pattern, bootstrap_source)
    @test !occursin("DATABASE_URL=postgres://inventory:inventory@", prd_source)
    @test occursin(raw"DATABASE_URL=postgres://inventory:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation", prd_source)
end
