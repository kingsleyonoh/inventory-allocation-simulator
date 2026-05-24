using Test
using UUIDs
using JSON3
using InventoryAllocationSimulator

function _catalog_function_block(source::AbstractString, signature::AbstractString, next_signature::AbstractString)::String
    start = findfirst(signature, source)
    stop = findfirst(next_signature, source)
    @test start !== nothing
    @test stop !== nothing
    return source[first(start):first(stop)-1]
end

function _found_before(candidate, first_later, second_later)::Bool
    candidate === nothing && return false
    first_later === nothing && return false
    second_later === nothing && return false
    return first(candidate) < first(first_later) < first(second_later)
end

@testset "Warehouse repository is tenant-scoped and validates writes" begin
    store = batch012_store()

    listed = list_warehouses(store, BATCH012_VIEWER_A).warehouses
    @test [row.code for row in listed] == ["BRI", "EDI"]
    @test !occursin("Wellington", JSON3.write(listed))

    region = list_warehouses(store, BATCH012_VIEWER_A; params = Dict("region" => "GB-SW")).warehouses
    @test length(region) == 1
    @test region[1].code == "BRI"

    created = create_warehouse!(store, BATCH012_PLANNER_A, Dict("code" => "MAN", "name" => "Manchester DC", "region" => "GB-NW", "capacity_units" => 2500, "handling_cost_cents" => 8))
    @test created.tenant_id == string(BATCH012_TENANT_A)
    @test created.active == true
    @test get_warehouse(store, BATCH012_ADMIN_A, created.id).code == "MAN"

    updated = update_warehouse!(store, BATCH012_ADMIN_A, created.id, Dict("capacity_units" => 3000, "active" => false))
    @test updated.capacity_units == 3000.0
    @test updated.active == false

    deactivated = deactivate_warehouse!(store, BATCH012_ADMIN_A, created.id)
    @test deactivated.active == false

    @test_throws AuthzError create_warehouse!(store, BATCH012_VIEWER_A, Dict("code" => "DENY", "name" => "Denied", "region" => "GB", "capacity_units" => 1))
    @test_throws ApiError create_warehouse!(store, BATCH012_PLANNER_A, Dict("code" => "BRI", "name" => "Duplicate", "region" => "GB", "capacity_units" => 1))
    @test_throws ApiError create_warehouse!(store, BATCH012_PLANNER_A, Dict("code" => "BAD", "name" => "Bad", "region" => "GB", "capacity_units" => -1))
    @test_throws ApiError get_warehouse(store, BATCH012_ADMIN_A, UUID("20000000-0000-4000-8000-000000000001"))
end

@testset "SKU repository is tenant-scoped and validates economics" begin
    store = batch012_store()

    listed = list_skus(store, BATCH012_VIEWER_A).skus
    @test [row.sku_code for row in listed] == ["SKU-BLUE", "SKU-RED"]
    @test !occursin("Kōwhai", JSON3.write(listed))

    filtered = list_skus(store, BATCH012_VIEWER_A; params = Dict("category" => "widgets", "status" => "active")).skus
    @test [row.sku_code for row in filtered] == ["SKU-RED"]

    created = create_sku!(store, BATCH012_PLANNER_A, Dict("sku_code" => "SKU-GREEN", "name" => "Green Widget", "category" => "widgets", "unit_volume" => 1.5, "unit_margin_cents" => 600, "stockout_cost_cents" => 950, "holding_cost_cents" => 30))
    @test created.tenant_id == string(BATCH012_TENANT_A)
    @test created.active == true
    @test get_sku(store, BATCH012_ADMIN_A, created.id).sku_code == "SKU-GREEN"

    updated = update_sku!(store, BATCH012_ADMIN_A, created.id, Dict("unit_margin_cents" => 650, "active" => false))
    @test updated.unit_margin_cents == 650
    @test updated.active == false

    deactivated = deactivate_sku!(store, BATCH012_ADMIN_A, created.id)
    @test deactivated.active == false

    @test_throws AuthzError create_sku!(store, BATCH012_VIEWER_A, Dict("sku_code" => "DENY", "name" => "Denied", "category" => "x"))
    @test_throws ApiError create_sku!(store, BATCH012_PLANNER_A, Dict("sku_code" => "SKU-RED", "name" => "Duplicate", "category" => "widgets"))
    @test_throws ApiError create_sku!(store, BATCH012_PLANNER_A, Dict("sku_code" => "SKU-BAD", "name" => "Bad", "category" => "widgets", "unit_volume" => 0))
    @test_throws ApiError get_sku(store, BATCH012_ADMIN_A, UUID("40000000-0000-4000-8000-000000000001"))
end

@testset "Warehouse and SKU SQL repositories keep tenant predicates on every query" begin
    source = read(joinpath(project_root(), "src", "planning", "catalog.jl"), String)
    lowered = lowercase(replace(source, r"\s+" => " "))

    @test occursin(r"from warehouses .* where tenant_id", lowered)
    @test occursin(r"from skus .* where tenant_id", lowered)
    @test occursin(r"where tenant_id .* and id", lowered)
    @test occursin(r"update warehouses .* where tenant_id", lowered)
    @test occursin(r"update skus .* where tenant_id", lowered)
    @test !occursin("from warehouses order by", lowered)
    @test !occursin("from skus order by", lowered)
end

@testset "SQL list filters are applied before pagination" begin
    source = read(joinpath(project_root(), "src", "planning", "catalog.jl"), String)
    warehouse_block = _catalog_function_block(
        source,
        "function fetch_warehouses(store::SqlTenantAdminStore",
        "function fetch_warehouse(store::SqlTenantAdminStore",
    )
    sku_block = _catalog_function_block(
        source,
        "function fetch_skus(store::SqlTenantAdminStore",
        "function fetch_sku(store::SqlTenantAdminStore",
    )

    warehouse_region_filter = findfirst("AND region =", warehouse_block)
    warehouse_status_filter = findfirst("AND active =", warehouse_block)
    warehouse_order = findfirst("ORDER BY code", warehouse_block)
    warehouse_limit = findfirst("LIMIT", warehouse_block)
    @test warehouse_region_filter !== nothing
    @test warehouse_status_filter !== nothing
    @test _found_before(warehouse_region_filter, warehouse_order, warehouse_limit)
    @test _found_before(warehouse_status_filter, warehouse_order, warehouse_limit)
    @test !occursin("row[:region] == page.filters", warehouse_block)
    @test !occursin("row[:active] == active", warehouse_block)

    sku_category_filter = findfirst("AND category =", sku_block)
    sku_status_filter = findfirst("AND active =", sku_block)
    sku_order = findfirst("ORDER BY sku_code", sku_block)
    sku_limit = findfirst("LIMIT", sku_block)
    @test sku_category_filter !== nothing
    @test sku_status_filter !== nothing
    @test _found_before(sku_category_filter, sku_order, sku_limit)
    @test _found_before(sku_status_filter, sku_order, sku_limit)
    @test !occursin("row[:category] == page.filters", sku_block)
    @test !occursin("row[:active] == active", sku_block)
end
