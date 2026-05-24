using Test
using UUIDs
using JSON3
using InventoryAllocationSimulator

const BATCH011_TENANT_A = UUID("11111111-1111-4111-8111-111111111111")
const BATCH011_TENANT_B = UUID("22222222-2222-4222-8222-222222222222")
const BATCH011_ADMIN_A = TenantContext(BATCH011_TENANT_A; user_id = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), role = "admin", auth_method = :session)
const BATCH011_PLANNER_A = TenantContext(BATCH011_TENANT_A; user_id = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), role = "planner", auth_method = :session)
const BATCH011_VIEWER_A = TenantContext(BATCH011_TENANT_A; user_id = UUID("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), role = "viewer", auth_method = :session)

function batch011_config(; self_registration = true)
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch011.duckdb",
        "SESSION_SECRET" => "batch011-session-secret-placeholder",
        "METRICS_TOKEN" => "batch011-metrics-token-placeholder",
        "SELF_REGISTRATION_ENABLED" => string(self_registration),
        "API_KEY_PREFIX" => "ias_test",
        "DEFAULT_ADMIN_EMAIL" => "admin@example.test",
    ))
end

function batch011_store()
    tenant_a = (
        id = BATCH011_TENANT_A,
        name = "Northstar Demo",
        legal_name = "Northstar Supply Ltd",
        full_legal_name = "Northstar Supply Limited, England and Wales",
        display_name = "Northstar Supply",
        address = Dict("city" => "Bristol", "country" => "GB"),
        registration = Dict("company_number" => "NS-GB-10448821"),
        contact = Dict("email" => "ops+northstar@example.test"),
        wordmark = "/tenant-assets/northstar-wordmark.svg",
        api_key_hash = hash_api_key("ias_test_northstar"),
        is_active = true,
    )
    tenant_b = (
        id = BATCH011_TENANT_B,
        name = "Kōwhai Logistics",
        legal_name = "Kōwhai Logistics NZ Limited",
        full_legal_name = "Kōwhai Logistics New Zealand Limited — Te Whanganui-a-Tara",
        display_name = "Kōwhai Logistics",
        address = Dict("city" => "Wellington", "country" => "NZ"),
        registration = Dict("company_number" => "NZBN-9429041234567"),
        contact = Dict("email" => "planning+kowhai@example.test"),
        wordmark = "/tenant-assets/kowhai-wordmark.svg",
        api_key_hash = hash_api_key("ias_test_kowhai"),
        is_active = true,
    )
    users = [
        (id = UUID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), tenant_id = BATCH011_TENANT_A, email = "admin@northstar.example.test", name = "Northstar Admin", role = "admin", is_active = true),
        (id = UUID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), tenant_id = BATCH011_TENANT_A, email = "planner@northstar.example.test", name = "Northstar Planner", role = "planner", is_active = true),
        (id = UUID("dddddddd-dddd-4ddd-8ddd-dddddddddddd"), tenant_id = BATCH011_TENANT_B, email = "admin@kowhai.example.test", name = "Kōwhai Admin", role = "admin", is_active = true),
    ]
    return MemoryTenantAdminStore([tenant_a, tenant_b], users)
end

@testset "Role-resource authorization registry is seeded from matrix and fails closed" begin
    registry = load_authz_registry(joinpath(project_root(), "tests", "fixtures", "authz_matrix.json"))

    @test authorize!(BATCH011_ADMIN_A, "write", "tenant_settings"; registry = registry) === BATCH011_ADMIN_A
    @test authorize!(BATCH011_PLANNER_A, "read", "tenant_settings"; registry = registry) === BATCH011_PLANNER_A
    @test_throws AuthzError authorize!(BATCH011_PLANNER_A, "write", "tenant_settings"; registry = registry)
    @test_throws AuthzError authorize!(BATCH011_VIEWER_A, "manage", "user_api_key"; registry = registry)
    @test_throws AuthzError authorize!(BATCH011_ADMIN_A, "export", "unregistered_resource"; registry = registry)

    @test length(registry.policies) == 30
    @test registry.source == "docs/inventory-allocation-simulator_prd.md §2b Roles × Resource Actions"
end

@testset "Tenant self-registration guard creates tenant API key only when enabled" begin
    store = batch011_store()
    disabled = batch011_config(; self_registration = false)
    enabled = batch011_config(; self_registration = true)

    @test_throws ApiError register_tenant!(store, disabled, Dict("name" => "Guarded Tenant"))
    created = register_tenant!(store, enabled, Dict("name" => "Atlas Demo"); key_material = "atlas-demo")
    @test created.name == "Atlas Demo"
    @test startswith(created.apiKey, "ias_test_")
    @test lookup_tenant_by_api_key_hash(store, hash_api_key(created.apiKey)).tenant_id == created.id

    @test_throws ApiError register_tenant!(store, enabled, Dict("name" => "  "))
end

@testset "Tenant profile and settings endpoints are tenant-scoped and admin-write protected" begin
    store = batch011_store()

    profile = get_tenant_profile(store, BATCH011_PLANNER_A)
    @test profile.id == string(BATCH011_TENANT_A)
    @test profile.display_name == "Northstar Supply"
    @test JSON3.write(profile) |> body -> !occursin("Kōwhai", body)

    updated = update_tenant_settings!(store, BATCH011_ADMIN_A, Dict("display_name" => "Northstar Operations", "contact" => Dict("email" => "control@northstar.example.test")))
    @test updated.display_name == "Northstar Operations"
    @test updated.contact["email"] == "control@northstar.example.test"

    @test_throws AuthzError update_tenant_settings!(store, BATCH011_PLANNER_A, Dict("display_name" => "Planner Edit"))
    @test_throws ApiError update_tenant_settings!(store, BATCH011_ADMIN_A, Dict("display_name" => ""))
end

@testset "User list/create/update is tenant-scoped and follows admin role matrix" begin
    store = batch011_store()

    users = list_users(store, BATCH011_ADMIN_A)
    @test length(users) == 2
    @test all(user -> user.tenant_id == string(BATCH011_TENANT_A), users)
    @test !occursin("kowhai", lowercase(JSON3.write(users)))

    created = create_user!(store, BATCH011_ADMIN_A, Dict("email" => "viewer@northstar.example.test", "name" => "Northstar Viewer", "role" => "viewer"))
    @test created.role == "viewer"
    @test created.tenant_id == string(BATCH011_TENANT_A)

    patched = update_user!(store, BATCH011_ADMIN_A, created.id, Dict("role" => "planner", "is_active" => false))
    @test patched.role == "planner"
    @test patched.is_active == false

    @test_throws AuthzError list_users(store, BATCH011_PLANNER_A)
    @test_throws AuthzError create_user!(store, BATCH011_VIEWER_A, Dict("email" => "blocked@example.test", "name" => "Blocked", "role" => "viewer"))
    @test_throws ApiError create_user!(store, BATCH011_ADMIN_A, Dict("email" => "bad@example.test", "name" => "Bad", "role" => "owner"))
    @test_throws ApiError update_user!(store, BATCH011_ADMIN_A, string(UUID("dddddddd-dddd-4ddd-8ddd-dddddddddddd")), Dict("role" => "viewer"))

    malformed = try
        update_user!(store, BATCH011_ADMIN_A, "not-a-user-uuid", Dict("role" => "viewer"))
    catch err
        err
    end
    @test malformed isa ApiError
    @test malformed.code == "VALIDATION_ERROR"
    @test malformed.status == 400
end

@testset "Tenant profile serialization treats nullable SQL identity fields as JSON null" begin
    row = Dict{Symbol,Any}(
        :id => BATCH011_TENANT_A,
        :name => "Northstar Demo",
        :legal_name => "Northstar Supply Ltd",
        :full_legal_name => "Northstar Supply Limited, England and Wales",
        :display_name => "Northstar Supply",
        :address => Dict("city" => "Bristol", "country" => "GB"),
        :registration => Dict("company_number" => "NS-GB-10448821"),
        :contact => Dict("email" => "ops+northstar@example.test"),
        :wordmark => missing,
    )

    profile = InventoryAllocationSimulator._tenant_response(row)
    @test profile.wordmark === nothing
    @test occursin("\"wordmark\":null", JSON3.write(profile))
end

@testset "Production authz registry is available without test fixtures" begin
    runtime_path = joinpath(project_root(), "config", "authz_matrix.json")
    source = read(joinpath(project_root(), "src", "tenant", "authz.jl"), String)
    dockerfile = read(joinpath(project_root(), "Dockerfile"), String)

    @test isfile(runtime_path)
    @test InventoryAllocationSimulator.AUTHZ_REGISTRY_PATH == runtime_path
    @test !occursin("tests", relpath(InventoryAllocationSimulator.AUTHZ_REGISTRY_PATH, project_root()))
    @test !occursin("tests", source)
    @test read(runtime_path, String) == read(joinpath(project_root(), "tests", "fixtures", "authz_matrix.json"), String)
    @test occursin("COPY config ./config", dockerfile)
end

@testset "Tenant admin routes have production rate-limit enforcement" begin
    services = build_services(batch011_config())
    expected_policies = [
        ("POST", "/api/tenants/register", 5, 3600),
        ("GET", "/tenants/me", 120, 60),
        ("GET", "/api/settings/tenant", 120, 60),
        ("PATCH", "/api/settings/tenant", 20, 60),
        ("GET", "/api/users", 60, 60),
        ("POST", "/api/users", 20, 60),
        ("PATCH", "/api/users/:id", 20, 60),
    ]

    for (method, path, limit, window_seconds) in expected_policies
        policy = default_rate_limit_policy(method, path)
        @test policy.limit == limit
        @test policy.window_seconds == window_seconds
    end

    policy = default_rate_limit_policy("POST", "/api/users")
    for _ in 1:policy.limit
        decision = InventoryAllocationSimulator._apply_rate_limit!(services, "POST", "/api/users", "tenant-admin-rate-test")
        @test decision.allowed
    end
    @test_throws ApiError InventoryAllocationSimulator._apply_rate_limit!(services, "POST", "/api/users", "tenant-admin-rate-test")

    controller = read(joinpath(project_root(), "src", "web", "controllers", "tenant_admin_controller.jl"), String)
    for handler in [
        "handle_register_tenant", "handle_tenant_me", "handle_get_tenant_settings", "handle_update_tenant_settings",
        "handle_list_users", "handle_create_user", "handle_update_user",
    ]
        handler_start = findfirst("function $handler", controller)
        @test handler_start !== nothing
        next_handler = findnext("function ", controller, last(handler_start) + 1)
        block = next_handler === nothing ? controller[first(handler_start):end] : controller[first(handler_start):first(next_handler)-1]
        @test occursin("_enforce_route_rate_limit!", block)
    end
end

@testset "SQL session lookup is backed by a production migration" begin
    migration = joinpath(project_root(), "migrations", "003_user_sessions.up.sql")
    admin_api = read(joinpath(project_root(), "src", "tenant", "admin_api.jl"), String)

    @test isfile(migration)
    sql = replace(lowercase(read(migration, String)), r"\s+" => " ")
    @test occursin("create table if not exists user_sessions", sql)
    @test occursin("tenant_id uuid not null references tenants(id)", sql)
    @test occursin("user_id uuid not null references users(id)", sql)
    @test occursin("expires_at timestamp not null", sql)
    @test occursin("lookup_session_record(store::sqltenantadminstore", lowercase(admin_api))
    @test occursin("from user_sessions", lowercase(admin_api))
    @test !occursin("lookup_session_record(::SqlTenantAdminStore, _session_id::String) = nothing", admin_api)
end

@testset "Batch 011 API routes are registered to production entrypoints" begin
    definitions = route_definitions()
    expected = Set([
        (:POST, "/api/tenants/register"),
        (:GET, "/tenants/me"),
        (:GET, "/api/settings/tenant"),
        (:PATCH, "/api/settings/tenant"),
        (:GET, "/api/users"),
        (:POST, "/api/users"),
        (:PATCH, "/api/users/:id"),
    ])
    actual = Set((def.method, def.path) for def in definitions)
    @test issubset(expected, actual)
end
