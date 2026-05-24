using Test

const SECURITY_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
security_readroot(path...) = read(joinpath(SECURITY_ROOT, path...), String)

@testset "First-run security contracts" begin
    bootstrap_source = security_readroot("src", "tenant", "bootstrap.jl")
    auth_source = security_readroot("src", "tenant", "auth.jl")
    prd_source = security_readroot("docs", "inventory-allocation-simulator_prd.md")

    @test occursin("RandomDevice", bootstrap_source)
    direct_default_rng_pattern = "rand(" * "UInt8"
    @test !occursin(direct_default_rng_pattern, bootstrap_source)
    @test occursin("hmac_sha256", auth_source)
    @test !occursin("sha256(string(secret", auth_source)
    @test !occursin("DATABASE_URL=postgres://inventory:inventory@", prd_source)
    @test occursin(raw"DATABASE_URL=postgres://inventory:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation", prd_source)
end

@testset "Production deployment security contracts" begin
    prod_compose = security_readroot("docker-compose.prod.yml")

    @test !occursin(raw"${POSTGRES_PASSWORD:-", prod_compose)
    @test occursin(raw"POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}", prod_compose)
    @test count(_ -> true, eachmatch(r"resources:\s*\n\s*limits:", prod_compose)) >= 3
    @test count(_ -> true, eachmatch(r"memory:\s*[0-9]+[mMgG]", prod_compose)) >= 3
end
