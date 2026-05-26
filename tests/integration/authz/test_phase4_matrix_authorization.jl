using Test
using UUIDs
using JSON3
using InventoryAllocationSimulator

const PHASE4_MATRIX_TENANT = UUID("43434343-4343-4434-8434-434343434343")

function phase4_matrix_ctx(role::AbstractString)::TenantContext
    user_id = role == "admin" ? UUID("aaaaaaaa-4343-4434-8434-434343434343") :
              role == "planner" ? UUID("bbbbbbbb-4343-4434-8434-434343434343") :
              UUID("cccccccc-4343-4434-8434-434343434343")
    return TenantContext(PHASE4_MATRIX_TENANT; user_id = user_id, role = String(role), auth_method = :session)
end

function phase4_matrix_allowed(path::AbstractString, resource::AbstractString, action::AbstractString)::Dict{String,Bool}
    matrix = JSON3.read(read(path, String))
    return Dict(String(policy.key) => Bool(policy.allowed) for policy in matrix.policies if String(policy.resource) == resource && String(policy.action) == action)
end

@testset "Integration authz matrix covers Phase 4 integration configure and metrics/readiness cells" begin
    root = project_root()
    fixture_path = joinpath(root, "tests", "fixtures", "authz_matrix.json")
    runtime_path = joinpath(root, "config", "authz_matrix.json")

    integration_expected = Dict(
        "admin:integration:configure" => true,
        "planner:integration:configure" => false,
        "viewer:integration:configure" => false,
    )
    metrics_expected = Dict(
        "admin:metrics_readiness:read" => true,
        "planner:metrics_readiness:read" => true,
        "viewer:metrics_readiness:read" => true,
    )

    @test phase4_matrix_allowed(fixture_path, "integration", "configure") == integration_expected
    @test phase4_matrix_allowed(runtime_path, "integration", "configure") == integration_expected
    @test phase4_matrix_allowed(fixture_path, "metrics_readiness", "read") == metrics_expected
    @test phase4_matrix_allowed(runtime_path, "metrics_readiness", "read") == metrics_expected

    @test authorize!(phase4_matrix_ctx("admin"), "configure", "integration") === phase4_matrix_ctx("admin")
    @test_throws AuthzError authorize!(phase4_matrix_ctx("planner"), "configure", "integration")
    @test_throws AuthzError authorize!(phase4_matrix_ctx("viewer"), "configure", "integration")

    for role in ("admin", "planner", "viewer")
        ctx = phase4_matrix_ctx(role)
        @test authorize_metrics_readiness!(ctx) === ctx
    end

    integrations_source = read(joinpath(root, "src", "web", "controllers", "ui_integrations_page.jl"), String)
    dashboard_source = read(joinpath(root, "src", "web", "controllers", "ui_session_catalog_handlers.jl"), String)
    @test occursin("authorize!(ctx, \"configure\", \"integration\")", integrations_source)
    @test occursin("authorize_metrics_readiness!(ctx)", dashboard_source)
end
