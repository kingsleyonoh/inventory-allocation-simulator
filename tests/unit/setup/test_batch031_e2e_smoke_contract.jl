using Test

const BATCH031_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch031_read(path...) = read(joinpath(BATCH031_ROOT, path...), String)
batch031_exists(path...) = ispath(joinpath(BATCH031_ROOT, path...))

@testset "Batch 031 Playwright setup-to-approval smoke contract" begin
    spec_path = joinpath("tests", "e2e", "setup-to-approval-smoke.spec.js")
    helper_path = joinpath("tests", "e2e", "helpers", "setup_to_approval_fixture.jl")
    script_path = joinpath(".yolo", "scripts", "run-batch-031-e2e.sh")

    @test batch031_exists(spec_path)
    @test batch031_exists(helper_path)
    @test batch031_exists(script_path)

    spec = batch031_read(spec_path)
    helper = batch031_read(helper_path)
    script = batch031_read(script_path)

    @test occursin("setup/login/import/simulation/approval", spec)
    @test occursin("scripts/migrate.jl", spec)
    @test occursin("scripts/setup.jl", helper)
    @test occursin("run-setup", spec)
    @test occursin("Your API Key:", helper)
    @test occursin("register_tenant!", helper) == false
    @test occursin("create_user!", helper) == false
    @test occursin("key_material", helper) == false
    @test occursin("/login", spec)
    @test occursin("/api/imports", spec)
    @test occursin("/api/simulations", spec)
    @test occursin("/api/recommendations", spec)
    @test occursin("/approve", spec)
    config = batch031_read("playwright.config.js")
    @test occursin("GENIE_LOG_REQUESTS", config)
    @test occursin("'false'", config)
    @test occursin("process_import_job!", helper)
    @test occursin("simulation_worker!", helper)
    @test occursin("approve_recommendation!", helper) == false
    @test occursin("COMPOSE_PROJECT_NAME", script)
    @test occursin("docker compose down -v --remove-orphans", script)
    @test findfirst("docker compose down -v --remove-orphans", script) < findfirst("docker compose up -d postgres redis", script)
end
