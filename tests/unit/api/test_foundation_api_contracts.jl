using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

@testset "Shared API error formatter returns PRD §8b response contract without internals" begin
    response = format_error_response("VALIDATION_ERROR", "Name is required"; details = [(field = "name", code = "required")])
    @test haskey(response, :error)
    @test response.error.code == "VALIDATION_ERROR"
    @test response.error.message == "Name is required"
    @test response.error.details == [(field = "name", code = "required")]

    status, body = endpoint_error_response(ApiError("NOT_FOUND", "Warehouse not found"; status = 404))
    parsed = JSON3.read(body)
    @test status == 404
    @test parsed.error.code == "NOT_FOUND"
    @test !occursin("Stacktrace", body)

    status_auth, body_auth = endpoint_error_response(AuthError("UNAUTHORIZED", "Authentication required"; status = 401))
    parsed_auth = JSON3.read(body_auth)
    @test status_auth == 401
    @test parsed_auth.error.code == "UNAUTHORIZED"

    status2, body2 = endpoint_error_response(ErrorException("connection refused at src/internal.jl:1"))
    parsed2 = JSON3.read(body2)
    @test status2 == 500
    @test parsed2.error.code == "INTERNAL_ERROR"
    @test !occursin("internal.jl", body2)
end

@testset "Cursor pagination and filters enforce defaults, max size, and allowed filters" begin
    params = Dict("limit" => "50", "cursor" => "2026-05-23T10:00:00Z|abc", "status" => "active", "region" => "north")
    page = parse_cursor_params(params; allowed_filters = Set(["status", "region"]))
    @test page.limit == 50
    @test page.cursor == "2026-05-23T10:00:00Z|abc"
    @test page.filters == Dict("status" => "active", "region" => "north")

    default_page = parse_cursor_params(Dict{String,String}(); allowed_filters = Set(["status"]))
    @test default_page.limit == 25
    @test default_page.cursor === nothing
    @test isempty(default_page.filters)

    @test_throws ApiError parse_cursor_params(Dict("limit" => "251"); allowed_filters = Set(["status"]))
    @test_throws ApiError parse_cursor_params(Dict("unknown" => "x"); allowed_filters = Set(["status"]))
end

@testset "Rate limiter allows configured quota and rejects excess action requests" begin
    base_time = DateTime(2026, 5, 23, 10, 0, 0)
    limiter = MemoryRateLimiter(() -> base_time)
    policy = RateLimitPolicy(2, 60, "POST /api/warehouses")

    first = check_rate_limit!(limiter, "tenant-a", policy)
    second = check_rate_limit!(limiter, "tenant-a", policy)
    third = check_rate_limit!(limiter, "tenant-a", policy)

    @test first.allowed
    @test second.allowed
    @test !third.allowed
    @test third.retry_after_seconds == 60

    other_tenant = check_rate_limit!(limiter, "tenant-b", policy)
    @test other_tenant.allowed
end

struct FakeAuthStore <: AbstractAuthStore
    tenants::Dict{String,TenantAuthRecord}
    sessions::Dict{String,SessionAuthRecord}
    api_lookup_count::Base.RefValue{Int}
    session_lookup_count::Base.RefValue{Int}
end

function InventoryAllocationSimulator.lookup_tenant_by_api_key_hash(store::FakeAuthStore, api_key_hash::String)
    store.api_lookup_count[] += 1
    return get(store.tenants, api_key_hash, nothing)
end

function InventoryAllocationSimulator.lookup_session_record(store::FakeAuthStore, session_id::String)
    store.session_lookup_count[] += 1
    return get(store.sessions, session_id, nothing)
end

@testset "API-key hashing, session auth, tenant context, and request cache resolve safely" begin
    base_time = DateTime(2026, 5, 23, 10, 0, 0)
    raw_key = "ias_live_test_api_key"
    tenant_id = UUID("33333333-3333-3333-3333-333333333333")
    user_id = UUID("44444444-4444-4444-4444-444444444444")
    key_hash = hash_api_key(raw_key)
    session_id = "session-123"
    secret = "session-secret-placeholder"
    signed_cookie = signed_session_cookie(session_id, secret)

    store = FakeAuthStore(
        Dict(key_hash => TenantAuthRecord(tenant_id, nothing, "planner", true)),
        Dict(session_id => SessionAuthRecord(tenant_id, user_id, "admin", true, DateTime(2026, 5, 23, 11, 0, 0))),
        Ref(0),
        Ref(0),
    )
    cache = RequestCache()

    api_ctx = resolve_tenant_context(store, AuthRequest(raw_key, nothing); cache = cache)
    api_ctx_again = resolve_tenant_context(store, AuthRequest(raw_key, nothing); cache = cache)
    @test api_ctx.tenant_id == tenant_id
    @test api_ctx.role == "planner"
    @test api_ctx.auth_method == :api_key
    @test api_ctx_again === api_ctx
    @test store.api_lookup_count[] == 1

    session_ctx = resolve_tenant_context(store, AuthRequest(nothing, signed_cookie); cache = RequestCache(), session_secret = secret, now = () -> base_time)
    @test session_ctx.tenant_id == tenant_id
    @test session_ctx.user_id == user_id
    @test session_ctx.role == "admin"
    @test session_ctx.auth_method == :session

    inactive_store = FakeAuthStore(Dict(key_hash => TenantAuthRecord(tenant_id, nothing, "viewer", false)), Dict{String,SessionAuthRecord}(), Ref(0), Ref(0))
    @test_throws AuthError resolve_tenant_context(inactive_store, AuthRequest(raw_key, nothing); cache = RequestCache())
    @test_throws AuthError resolve_tenant_context(store, AuthRequest(nothing, "bad.cookie"); cache = RequestCache(), session_secret = secret)
    @test_throws AuthError resolve_tenant_context(store, AuthRequest(nothing, nothing); cache = RequestCache())
end
