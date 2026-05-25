using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

const REC_MATRIX_TENANT = UUID("32323232-3232-4323-8323-323232323232")
const REC_MATRIX_RUN = UUID("32323232-0000-4000-8000-000000000001")
const REC_MATRIX_FROM_WH = UUID("32323232-1000-4000-8000-000000000001")
const REC_MATRIX_TO_WH = UUID("32323232-1000-4000-8000-000000000002")
const REC_MATRIX_SKU = UUID("32323232-3000-4000-8000-000000000001")

function rec_matrix_ctx(role::AbstractString)::TenantContext
    user_id = role == "admin" ? UUID("aaaaaaaa-3232-4323-8323-323232323232") :
              role == "planner" ? UUID("bbbbbbbb-3232-4323-8323-323232323232") :
              UUID("cccccccc-3232-4323-8323-323232323232")
    return TenantContext(REC_MATRIX_TENANT; user_id = user_id, role = String(role), auth_method = :session)
end

function rec_matrix_tenants()
    return [(
        id = REC_MATRIX_TENANT, name = "Recommendation Matrix Tenant", legal_name = "Recommendation Matrix Ltd",
        full_legal_name = "Recommendation Matrix Limited", display_name = "Recommendation Matrix",
        address = Dict("city" => "Cardiff"), registration = Dict("company_number" => "REC-MATRIX"),
        contact = Dict("email" => "rec-matrix@example.test"), wordmark = nothing,
        api_key_hash = hash_api_key("ias_test_rec_matrix"), is_active = true,
    )]
end

function rec_matrix_users()
    return [
        (id = rec_matrix_ctx("admin").user_id, tenant_id = REC_MATRIX_TENANT, email = "admin@rec-matrix.example.test", name = "Matrix Admin", role = "admin", is_active = true),
        (id = rec_matrix_ctx("planner").user_id, tenant_id = REC_MATRIX_TENANT, email = "planner@rec-matrix.example.test", name = "Matrix Planner", role = "planner", is_active = true),
        (id = rec_matrix_ctx("viewer").user_id, tenant_id = REC_MATRIX_TENANT, email = "viewer@rec-matrix.example.test", name = "Matrix Viewer", role = "viewer", is_active = true),
    ]
end

function rec_matrix_recommendation(id::UUID; status = "proposed")
    created_at = DateTime(2026, 5, 25, 9)
    return (
        id = id,
        tenant_id = REC_MATRIX_TENANT,
        simulation_run_id = REC_MATRIX_RUN,
        from_warehouse_id = REC_MATRIX_FROM_WH,
        to_warehouse_id = REC_MATRIX_TO_WH,
        sku_id = REC_MATRIX_SKU,
        transfer_units = 10.0,
        expected_stockout_reduction_units = 12.0,
        expected_margin_gain_cents = 6000,
        transfer_cost_cents = 1250,
        net_value_cents = 4750,
        confidence_score = 0.81,
        explanation = Dict(
            "binding_constraints" => ["lane capacity"],
            "scenario_sensitivity" => Dict("scenario_count" => 2),
            "accepted_tradeoffs" => ["cost accepted for service"],
        ),
        status = status,
        created_at = created_at,
        updated_at = created_at,
    )
end

function rec_matrix_store(; recommendation_status = "proposed")::MemoryTenantAdminStore
    recommendation_id = uuid4()
    return MemoryTenantAdminStore(
        rec_matrix_tenants(),
        rec_matrix_users();
        allocation_recommendations = [rec_matrix_recommendation(recommendation_id; status = recommendation_status)],
    )
end

function rec_matrix_only_recommendation_id(store::MemoryTenantAdminStore)::UUID
    return only(keys(store.allocation_recommendations))
end

function rec_matrix_allowed(path::AbstractString)::Dict{String,Bool}
    matrix = JSON3.read(read(path, String))
    return Dict(String(policy.key) => Bool(policy.allowed) for policy in matrix.policies if String(policy.resource) == "recommendation" && String(policy.action) == "decide_export")
end

@testset "Integration authz matrix covers recommendation decide/export role cells" begin
    root = project_root()
    fixture_allowed = rec_matrix_allowed(joinpath(root, "tests", "fixtures", "authz_matrix.json"))
    runtime_allowed = rec_matrix_allowed(joinpath(root, "config", "authz_matrix.json"))
    expected = Dict(
        "admin:recommendation:decide_export" => true,
        "planner:recommendation:decide_export" => true,
        "viewer:recommendation:decide_export" => false,
    )
    @test fixture_allowed == expected
    @test runtime_allowed == expected

    for role in ("admin", "planner")
        approve_store = rec_matrix_store()
        approve_id = rec_matrix_only_recommendation_id(approve_store)
        approved = approve_recommendation!(approve_store, rec_matrix_ctx(role), approve_id, Dict("reason" => "$(role) accepted service tradeoff"))
        @test approved.recommendation.status == "approved"
        @test approved.decision.decision == "approved"

        export_store = rec_matrix_store(recommendation_status = "approved")
        export_id = rec_matrix_only_recommendation_id(export_store)
        exported = export_recommendation!(export_store, rec_matrix_ctx(role), export_id, Dict("reason" => "$(role) exported transfer plan"))
        @test exported.recommendation.status == "exported"
        @test exported.decision.decision == "exported"

        csv_store = rec_matrix_store(recommendation_status = "approved")
        csv_id = rec_matrix_only_recommendation_id(csv_store)
        csv = export_recommendation_csv(csv_store, rec_matrix_ctx(role), csv_id)
        @test csv.content_type == "text/csv; charset=utf-8"
        @test occursin(string(csv_id), csv.body)
    end

    viewer = rec_matrix_ctx("viewer")
    approve_denied_store = rec_matrix_store()
    export_denied_store = rec_matrix_store(recommendation_status = "approved")
    csv_denied_store = rec_matrix_store(recommendation_status = "approved")
    @test_throws AuthzError approve_recommendation!(approve_denied_store, viewer, rec_matrix_only_recommendation_id(approve_denied_store), Dict("reason" => "viewer denied"))
    @test_throws AuthzError export_recommendation!(export_denied_store, viewer, rec_matrix_only_recommendation_id(export_denied_store), Dict("reason" => "viewer denied"))
    @test_throws AuthzError export_recommendation_csv(csv_denied_store, viewer, rec_matrix_only_recommendation_id(csv_denied_store))
end
