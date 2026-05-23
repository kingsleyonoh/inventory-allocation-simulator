using Test
using JSON3

const BATCH004_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch004_path(parts...) = joinpath(BATCH004_ROOT, parts...)
batch004_read(parts...) = read(batch004_path(parts...), String)

function batch004_json(parts...)
    return JSON3.read(batch004_read(parts...))
end

@testset "Playwright E2E smoke framework runs against real HTTP" begin
    config_path = batch004_path("playwright.config.js")
    smoke_path = batch004_path("tests", "e2e", "health.spec.js")

    @test isfile(config_path)
    @test isfile(smoke_path)

    config = batch004_read("playwright.config.js")
    @test occursin("webServer", config)
    @test occursin("julia --project src/Main.jl", config)
    @test occursin("127.0.0.1", config)
    @test occursin("baseURL", config)
    @test occursin("tests/e2e", config)
    @test !occursin("SKIPPED", uppercase(config))

    smoke = batch004_read("tests", "e2e", "health.spec.js")
    @test occursin("request.get('/health')", smoke)
    @test occursin("inventory-allocation-simulator", smoke)
    @test occursin("request.get('/__missing_smoke_route__')", smoke)
    @test occursin("404", smoke)
end

@testset "Runtime artifacts expose runnable E2E command and no protected rules path" begin
    gate = batch004_read(".yolo", "gates", "e2e-batch-004.md")
    implement_result = batch004_json(".yolo", "batch-results", "batch-004-implement.json")

    @test occursin("result: PASSED", gate)
    @test occursin("endpoints_touched: yes", gate)
    @test occursin("command: npx playwright test", gate)
    @test String(implement_result.tests.e2e.command) == "npx playwright test"
    @test !(".agent/rules/CODEBASE_CONTEXT.md" in String.(implement_result.filesChanged))
end

@testset "Authz matrix fixture covers every PRD role/resource cell" begin
    matrix = batch004_json("tests", "fixtures", "authz_matrix.json")
    @test matrix.schemaVersion == 1
    @test collect(String.(matrix.roles)) == ["admin", "planner", "viewer"]
    @test length(matrix.resourceActionGroups) == 10
    @test length(matrix.policies) == 30

    expected = Dict(
        "admin:tenant_settings:read" => true,
        "admin:tenant_settings:write" => true,
        "admin:user_api_key:manage" => true,
        "admin:planning_data:read" => true,
        "admin:planning_data:write_import" => true,
        "admin:policy:manage" => true,
        "admin:simulation:run_cancel" => true,
        "admin:recommendation:decide_export" => true,
        "admin:integration:configure" => true,
        "admin:metrics_readiness:read" => true,
        "planner:tenant_settings:read" => true,
        "planner:tenant_settings:write" => false,
        "planner:user_api_key:manage" => false,
        "planner:planning_data:read" => true,
        "planner:planning_data:write_import" => true,
        "planner:policy:manage" => true,
        "planner:simulation:run_cancel" => true,
        "planner:recommendation:decide_export" => true,
        "planner:integration:configure" => false,
        "planner:metrics_readiness:read" => true,
        "viewer:tenant_settings:read" => true,
        "viewer:tenant_settings:write" => false,
        "viewer:user_api_key:manage" => false,
        "viewer:planning_data:read" => true,
        "viewer:planning_data:write_import" => false,
        "viewer:policy:manage" => false,
        "viewer:simulation:run_cancel" => false,
        "viewer:recommendation:decide_export" => false,
        "viewer:integration:configure" => false,
        "viewer:metrics_readiness:read" => true,
    )

    observed = Dict{String,Bool}()
    for policy in matrix.policies
        observed[String(policy.key)] = Bool(policy.allowed)
        @test String(policy.key) == "$(policy.role):$(policy.resource):$(policy.action)"
    end
    @test observed == expected
end

@testset "Two-tenant identity fixtures expose cross-tenant leakage" begin
    tenants = batch004_json("tests", "fixtures", "tenants.json")
    @test tenants.schemaVersion == 1
    @test length(tenants.tenants) >= 2

    first_tenant = tenants.tenants[1]
    second_tenant = tenants.tenants[2]
    identity_paths = [
        (:name,), (:legal_name,), (:full_legal_name,), (:display_name,),
        (:address, :line1), (:address, :city), (:address, :country),
        (:registration, :company_number), (:registration, :tax_id),
        (:contact, :email), (:contact, :phone), (:contact, :escalation_url),
        (:wordmark,),
    ]

    for path in identity_paths
        left = first_tenant
        right = second_tenant
        for key in path
            left = getproperty(left, key)
            right = getproperty(right, key)
        end
        @test !isempty(String(left))
        @test !isempty(String(right))
        @test String(left) != String(right)
    end
end

@testset "Business correctness harness enumerates PRD success criteria surfaces" begin
    manifest = batch004_json("tests", "fixtures", "correctness", "manifest.json")
    expected_ids = Set([
        "imports_mixed_valid_invalid_rows",
        "forecast_stockout_history_not_low_demand",
        "solver_known_optimum_small_network",
        "recommendation_net_value_parity",
        "notification_local_fallback_when_hub_disabled_or_failing",
        "adapter_failure_does_not_mutate_core_truth",
    ])
    observed_ids = Set(String.(scenario.id for scenario in manifest.scenarios))
    @test observed_ids == expected_ids

    for scenario in manifest.scenarios
        @test startswith(String(scenario.sourceOfTruth), "docs/inventory-allocation-simulator_prd.md §")
        @test length(scenario.observablePaths) >= 2
        @test !isempty(String(scenario.failureModeProtected))
        for fixture_path in scenario.fixtures
            @test isfile(batch004_path(split(String(fixture_path), '/')...))
        end
    end
end

@testset "Request cache helper memoizes expensive per-request work without caching failures" begin
    cache = InventoryAllocationSimulator.RequestCache()
    calls = Ref(0)
    value1 = InventoryAllocationSimulator.get_cached!(cache, :tenant_profile) do
        calls[] += 1
        return "Tenant Profile"
    end
    value2 = InventoryAllocationSimulator.get_cached!(cache, :tenant_profile) do
        calls[] += 1
        return "Wrong Tenant"
    end
    @test value1 == "Tenant Profile"
    @test value2 == "Tenant Profile"
    @test calls[] == 1
    @test InventoryAllocationSimulator.cache_keys(cache) == Set([:tenant_profile])

    failing_cache = InventoryAllocationSimulator.RequestCache()
    @test_throws ArgumentError InventoryAllocationSimulator.get_cached!(failing_cache, :broken) do
        throw(ArgumentError("loader failed"))
    end
    @test isempty(InventoryAllocationSimulator.cache_keys(failing_cache))
end

@testset "Frontend product and design baselines encode PRD section 5b quality gates" begin
    product = batch004_read("PRODUCT.md")
    design = batch004_read("DESIGN.md")

    for token in ["dense", "operations console", "tenant", "CSV", "optional ecosystem adapters"]
        @test occursin(token, product)
    end
    for token in ["390px", "WCAG 2.1 AA", "semantic", "focus", "no color-only", "lazy-load charting", "explicit user action"]
        @test occursin(token, design)
    end
    @test occursin("uploaded CSV data stays local to tenant", design)
end

@testset "Architecture docs record shared cached helper pattern without protected-rule edits" begin
    protected_diff = read(`git -C $BATCH004_ROOT diff --name-only -- .agent/rules/CODEBASE_CONTEXT.md`, String)
    foundation_index = batch004_read(".agent", "knowledge", "foundation", "_index.md")
    helper_doc = batch004_read(".agent", "knowledge", "foundation", "request-cached-helpers.md")

    @test isempty(strip(protected_diff))
    @test occursin("request-cached-helpers.md", foundation_index)
    @test occursin("get_cached!", helper_doc)
    @test occursin("per tenant request", helper_doc)
end
