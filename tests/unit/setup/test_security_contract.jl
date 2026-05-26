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

@testset "Phase 3 UI security contracts" begin
    ui_session_handlers = security_readroot("src", "web", "controllers", "ui_session_catalog_handlers.jl")
    ui_phase3_handlers = security_readroot("src", "web", "controllers", "ui_phase3_form_handlers.jl")
    ui_handlers = ui_session_handlers * "\n" * ui_phase3_handlers

    @test !occursin("sprint(showerror, err)", ui_handlers)
    @test occursin("_ui_unavailable_response", ui_handlers)
    for title in [
        "Dashboard unavailable", "Imports unavailable", "Warehouses unavailable", "SKUs unavailable",
        "Transfer lanes unavailable", "Policies unavailable", "Settings unavailable", "Simulations unavailable",
        "Simulation detail unavailable", "Notifications unavailable", "Recommendation unavailable",
    ]
        @test occursin("_ui_unavailable_response(\"$title\"", ui_handlers)
    end
end

@testset "Production deployment security contracts" begin
    prod_compose = security_readroot("docker-compose.prod.yml")

    @test !occursin(raw"${POSTGRES_PASSWORD:-", prod_compose)
    @test occursin(raw"POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}", prod_compose)
    @test count(_ -> true, eachmatch(r"resources:\s*\n\s*limits:", prod_compose)) >= 3
    @test count(_ -> true, eachmatch(r"memory:\s*[0-9]+[mMgG]", prod_compose)) >= 3
end

@testset "Phase 4 adapter security contracts" begin
    status_probe_source = security_readroot("src", "integrations", "status_probe.jl")
    integration_controller_source = security_readroot("src", "web", "controllers", "integration_controller.jl")
    metrics_source = security_readroot("src", "observability", "metrics_prometheus.jl")

    @test occursin("Adapter health check failed", status_probe_source)
    @test !occursin(raw"Adapter failed: $(sprint(showerror, err))", status_probe_source)
    @test count(occursin.(Ref("authorize!(ctx, \"configure\", \"integration\")"), split(integration_controller_source, '\n'))) >= 2
    @test occursin("metrics_authorized", metrics_source)
    @test occursin("candidate == token", metrics_source)
end
