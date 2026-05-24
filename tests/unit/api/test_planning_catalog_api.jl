using Test
using UUIDs
using JSON3
using InventoryAllocationSimulator

@testset "API key rotation returns raw key once and persists only the hash" begin
    store = batch012_store()
    config = batch012_config()

    before_hash = store.tenants[BATCH012_TENANT_A][:api_key_hash]
    rotated = rotate_api_key!(store, config, BATCH012_ADMIN_A; key_material = "rotated-northstar-key")

    @test startswith(rotated.apiKey, "ias_test_")
    @test rotated.apiKeyHash === nothing
    @test store.tenants[BATCH012_TENANT_A][:api_key_hash] == hash_api_key(rotated.apiKey)
    @test store.tenants[BATCH012_TENANT_A][:api_key_hash] != before_hash
    @test lookup_tenant_by_api_key_hash(store, before_hash) === nothing
    @test lookup_tenant_by_api_key_hash(store, hash_api_key(rotated.apiKey)).tenant_id == BATCH012_TENANT_A
    @test !occursin(hash_api_key(rotated.apiKey), JSON3.write(rotated))

    @test_throws AuthzError rotate_api_key!(store, config, BATCH012_PLANNER_A; key_material = "blocked")
end

@testset "Planning API route inventory and authorization contracts are wired" begin
    definitions = route_definitions()
    expected = Set([
        (:POST, "/api/settings/api-key/rotate"),
        (:GET, "/api/warehouses"),
        (:POST, "/api/warehouses"),
        (:GET, "/api/warehouses/:id"),
        (:PATCH, "/api/warehouses/:id"),
        (:DELETE, "/api/warehouses/:id"),
        (:GET, "/api/skus"),
        (:POST, "/api/skus"),
        (:GET, "/api/skus/:id"),
        (:PATCH, "/api/skus/:id"),
        (:DELETE, "/api/skus/:id"),
        (:GET, "/api/inventory"),
        (:PUT, "/api/inventory/:id"),
        (:GET, "/api/demand-history"),
        (:GET, "/api/lanes"),
        (:POST, "/api/lanes"),
    ])
    actual = Set((def.method, def.path) for def in definitions)
    @test issubset(expected, actual)

    controller = read(joinpath(project_root(), "src", "web", "controllers", "planning_catalog_controller.jl"), String)
    for handler in [
        "handle_rotate_api_key", "handle_list_warehouses", "handle_create_warehouse", "handle_get_warehouse",
        "handle_update_warehouse", "handle_delete_warehouse", "handle_list_skus", "handle_create_sku",
        "handle_get_sku", "handle_update_sku", "handle_delete_sku", "handle_list_inventory",
        "handle_update_inventory", "handle_list_demand_history", "handle_list_lanes", "handle_create_lane",
    ]
        handler_start = findfirst("function $handler", controller)
        @test handler_start !== nothing
        next_handler = findnext("function ", controller, last(handler_start) + 1)
        block = next_handler === nothing ? controller[first(handler_start):end] : controller[first(handler_start):first(next_handler)-1]
        @test occursin("_enforce_route_rate_limit!", block)
        @test occursin("_protected_context_and_store", block)
    end
end

@testset "Inventory demand and lane API services expose pagination filters and validation" begin
    store = batch012_store()

    inventory = list_inventory_positions(store, BATCH012_VIEWER_A; params = Dict("limit" => "1", "warehouse_id" => "10000000-0000-4000-8000-000000000001")).inventory
    @test length(inventory) == 1
    @test inventory[1].available_units == 90.0
    @test_throws ApiError list_inventory_positions(store, BATCH012_VIEWER_A; params = Dict("unknown" => "x"))

    demand = list_demand_history(store, BATCH012_VIEWER_A; params = Dict("limit" => "1", "sku_id" => "30000000-0000-4000-8000-000000000001")).demand_history
    @test demand[1].stockout_adjusted_demand_units == 95.0
    @test_throws ApiError list_demand_history(store, BATCH012_VIEWER_A; params = Dict("unknown" => "x"))

    new_warehouse = create_warehouse!(store, BATCH012_PLANNER_A, Dict("code" => "LON", "name" => "London DC", "region" => "GB-LDN", "capacity_units" => 4000))
    lane = create_transfer_lane!(store, BATCH012_PLANNER_A, Dict("from_warehouse_id" => "10000000-0000-4000-8000-000000000001", "to_warehouse_id" => new_warehouse.id, "lead_time_days" => 1, "cost_per_unit_cents" => 25))
    @test lane.active == true
    @test_throws ApiError list_transfer_lanes(store, BATCH012_VIEWER_A; params = Dict("status" => "retired"))
    @test_throws AuthzError create_transfer_lane!(store, BATCH012_VIEWER_A, Dict("from_warehouse_id" => "10000000-0000-4000-8000-000000000001", "to_warehouse_id" => new_warehouse.id, "lead_time_days" => 1))
end

@testset "Planning API service validation mirrors repository rules" begin
    store = batch012_store()

    warehouse = create_warehouse!(store, BATCH012_PLANNER_A, Dict("code" => "LON", "name" => "London DC", "region" => "GB-LDN", "capacity_units" => 4000))
    sku = create_sku!(store, BATCH012_PLANNER_A, Dict("sku_code" => "SKU-YELLOW", "name" => "Yellow Widget", "category" => "widgets"))

    @test warehouse.code == "LON"
    @test sku.sku_code == "SKU-YELLOW"
    @test_throws AuthzError update_warehouse!(store, BATCH012_VIEWER_A, warehouse.id, Dict("name" => "Viewer Edit"))
    @test_throws AuthzError update_sku!(store, BATCH012_VIEWER_A, sku.id, Dict("name" => "Viewer Edit"))
    @test_throws ApiError update_warehouse!(store, BATCH012_PLANNER_A, warehouse.id, Dict("latitude" => 99))
    @test_throws ApiError update_sku!(store, BATCH012_PLANNER_A, sku.id, Dict("holding_cost_cents" => -1))
end
