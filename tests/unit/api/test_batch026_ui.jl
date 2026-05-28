using Test
using Dates
using UUIDs
using InventoryAllocationSimulator

@testset "Batch 026 UI route inventory and protected-route contracts are wired" begin
    definitions = route_definitions()
    expected = Set([
        (:GET, "/"),
        (:GET, "/login"),
        (:POST, "/login"),
        (:POST, "/logout"),
        (:GET, "/dashboard"),
        (:GET, "/imports"),
        (:POST, "/imports"),
        (:GET, "/warehouses"),
        (:GET, "/skus"),
    ])
    actual = Set((def.method, def.path) for def in definitions)
    @test issubset(expected, actual)

    controller_path = joinpath(project_root(), "src", "web", "controllers", "ui_controller.jl")
    @test isfile(controller_path)
    controller = read(controller_path, String)
    for handler in ["handle_dashboard", "handle_imports_page", "handle_warehouses_page", "handle_skus_page"]
        handler_start = findfirst("function $handler", controller)
        @test handler_start !== nothing
        next_handler = findnext("function ", controller, last(handler_start) + 1)
        block = next_handler === nothing ? controller[first(handler_start):end] : controller[first(handler_start):first(next_handler)-1]
        @test occursin("_protected_ui_context_and_store", block)
        @test occursin("_html_response", block)
    end
end

@testset "Batch 026 login page and protected-route response are accessible and explicit" begin
    login = render_login_page()
    @test occursin("<form", login)
    @test occursin("method=\"post\"", login)
    @test occursin("action=\"/login\"", login)
    @test occursin("name=\"api_key\"", login)
    @test occursin("name=\"email\"", login)
    @test occursin("aria-describedby=\"login-guidance\"", login)
    @test occursin("Operations console sign in", login)

    invalid = render_login_page(error = "Invalid API key")
    @test occursin("role=\"alert\"", invalid)
    @test occursin("Invalid API key", invalid)

    protected = render_protected_route_notice("/dashboard")
    @test occursin("Authentication required", protected)
    @test occursin("href=\"/login?next=%2Fdashboard\"", protected)

    @test InventoryAllocationSimulator._safe_ui_next("/warehouses") == "/warehouses"
    @test InventoryAllocationSimulator._safe_ui_next("https://evil.example/phish") == "/dashboard"
    @test InventoryAllocationSimulator._safe_ui_next("//evil.example/phish") == "/dashboard"
    @test InventoryAllocationSimulator._safe_ui_next("dashboard") == "/dashboard"
    @test InventoryAllocationSimulator._safe_ui_next("/api/warehouses") == "/dashboard"
end

@testset "Batch 026 API-key UI login mints signed sessions and rejects wrong-tenant users" begin
    store = batch012_store()
    config = batch012_config()
    session = authenticate_ui_login!(
        store,
        config,
        Dict("api_key" => "ias_test_northstar", "email" => "admin@northstar.example.test");
        now = () -> DateTime(2026, 5, 25, 9),
    )
    session_id = verify_session_cookie(session.cookie, config.tenant.session_secret)
    @test !isempty(session_id)
    @test session.user_id == string(BATCH012_ADMIN_A.user_id)
    @test session.expires_at == DateTime(2026, 5, 25, 21)

    @test_throws AuthError authenticate_ui_login!(store, config, Dict("api_key" => "ias_test_northstar", "email" => "admin@kowhai.example.test"))
    @test_throws AuthError authenticate_ui_login!(store, config, Dict("api_key" => "bad-key", "email" => "admin@northstar.example.test"))
end

@testset "Batch 026 dashboard summarizes tenant-scoped operations state" begin
    store = batch012_store()
    run = create_simulation_run!(store, BATCH012_PLANNER_A, Dict(
        "policy_id" => string(UUID("b0000000-0000-4000-8000-000000000001")),
        "name" => "Morning allocation",
        "scenario_count" => 3,
    ))
    rec_id = UUID("d0000000-0000-4000-8000-000000000001")
    store.allocation_recommendations[rec_id] = Dict{Symbol,Any}(
        :id => rec_id,
        :tenant_id => BATCH012_TENANT_A,
        :simulation_run_id => UUID(run.id),
        :from_warehouse_id => UUID("10000000-0000-4000-8000-000000000001"),
        :to_warehouse_id => UUID("10000000-0000-4000-8000-000000000002"),
        :sku_id => UUID("30000000-0000-4000-8000-000000000001"),
        :transfer_units => 12.0,
        :expected_stockout_reduction_units => 18.0,
        :expected_margin_gain_cents => 9900,
        :transfer_cost_cents => 1500,
        :net_value_cents => 8400,
        :confidence_score => 0.82,
        :explanation => Dict("binding_constraints" => ["lane capacity"]),
        :status => "proposed",
        :created_at => DateTime(2026, 5, 25, 9),
    )

    html = render_dashboard_page(store, BATCH012_VIEWER_A)
    @test occursin("Stockout risk", html)
    @test occursin("1 risky position", html)
    @test occursin("Pending recommendations", html)
    @test occursin("1 pending", html)
    @test occursin("Morning allocation", html)
    @test occursin("Local alerts", html)
    @test occursin("0 unread", html)
    @test !occursin("Kōwhai", html)
end

@testset "Batch 026 Import Center renders upload guidance, failed status, row errors, and retry" begin
    store = batch012_store()
    config = batch014_config(upload_storage_path = mktempdir())
    content = "warehouse_code,sku_code,on_hand_units\nBRI,UNKNOWN,5\n"
    job = create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", "inventory-errors.csv", content)
    processed = process_import_job!(store, config, BATCH012_PLANNER_A, job.id)
    @test processed.status == "failed"
    @test !isempty(processed.error_report)

    html = render_import_center_page(store, BATCH012_PLANNER_A)
    @test occursin("Import Center", html)
    @test occursin("Upload CSV", html)
    @test occursin("action=\"/imports\"", html)
    @test !occursin("action=\"/api/imports\"", html)
    @test occursin("warehouse_code,sku_code,on_hand_units", html)
    @test occursin("inventory-errors.csv", html)
    @test occursin("failed", html)
    @test occursin("UNKNOWN_SKU", html)
    @test occursin("Retry upload", html)

    ui_store = batch012_store()
    ui_config = batch014_config(upload_storage_path = mktempdir())
    processed_ui = InventoryAllocationSimulator._create_and_process_import_from_ui!(ui_store, ui_config, BATCH012_PLANNER_A, (
        import_type = "warehouses",
        original_filename = "ui-warehouses.csv",
        content = "code,name,region,capacity_units\nLON,London DC,GB-LDN,420\n",
    ))
    @test processed_ui.status == "completed"
    @test any(w -> w.code == "LON" && w.name == "London DC", list_warehouses(ui_store, BATCH012_PLANNER_A).warehouses)
end

@testset "Batch 026 warehouse management page exposes create edit deactivate flows without cross-tenant leakage" begin
    store = batch012_store()
    html = render_warehouses_page(store, BATCH012_PLANNER_A)
    @test occursin("Warehouse management", html)
    @test occursin("action=\"/warehouses\"", html)
    @test !occursin("action=\"/api/warehouses", html)
    @test occursin("name=\"capacity_units\"", html)
    @test occursin("Bristol DC", html)
    @test occursin("Edit BRI", html)
    @test occursin("Deactivate BRI", html)
    @test occursin("aria-label=\"Warehouse active state for BRI\"", html)
    @test !occursin("Wellington DC", html)

    routes = Set((def.method, def.path) for def in route_definitions())
    @test (:POST, "/warehouses") in routes
    @test (:POST, "/warehouses/:id") in routes

    created = InventoryAllocationSimulator._apply_warehouse_ui_form!(store, BATCH012_PLANNER_A, Dict(
        "code" => "lon", "name" => "London DC", "region" => "GB-LDN",
        "capacity_units" => "420", "handling_cost_cents" => "9",
    ))
    @test created.code == "LON"
    @test get_warehouse(store, BATCH012_PLANNER_A, created.id).name == "London DC"

    bristol_id = "10000000-0000-4000-8000-000000000001"
    updated = InventoryAllocationSimulator._apply_warehouse_ui_form!(store, BATCH012_PLANNER_A, Dict(
        "name" => "Bristol North DC", "region" => "South West",
        "capacity_units" => "950", "handling_cost_cents" => "7",
    ); warehouse_id = bristol_id)
    @test updated.name == "Bristol North DC"
    deactivated = InventoryAllocationSimulator._apply_warehouse_ui_form!(store, BATCH012_PLANNER_A, Dict("active" => "false"); warehouse_id = bristol_id)
    @test deactivated.active == false

    @test_throws AuthzError InventoryAllocationSimulator._apply_warehouse_ui_form!(store, BATCH012_VIEWER_A, Dict("active" => "false"); warehouse_id = bristol_id)

    viewer_html = render_warehouses_page(store, BATCH012_VIEWER_A)
    @test occursin("Permission required to change warehouses", viewer_html)
    @test !occursin("Deactivate BRI", viewer_html)
end

@testset "Batch 026 SKU management page exposes economics, categories, and active-state controls" begin
    store = batch012_store()
    html = render_skus_page(store, BATCH012_PLANNER_A)
    @test occursin("SKU management", html)
    @test occursin("action=\"/skus\"", html)
    @test !occursin("action=\"/api/skus", html)
    @test occursin("name=\"unit_margin_cents\"", html)
    @test occursin("name=\"stockout_cost_cents\"", html)
    @test occursin("name=\"holding_cost_cents\"", html)
    @test occursin("Red Widget", html)
    @test occursin("widgets", html)
    @test occursin("Deactivate SKU-RED", html)
    @test occursin("Inactive", html)
    @test !occursin("Kōwhai Pack", html)

    routes = Set((def.method, def.path) for def in route_definitions())
    @test (:POST, "/skus") in routes
    @test (:POST, "/skus/:id") in routes

    created = InventoryAllocationSimulator._apply_sku_ui_form!(store, BATCH012_PLANNER_A, Dict(
        "sku_code" => "sku-gold", "name" => "Gold Widget", "category" => "widgets",
        "unit_volume" => "1.25", "unit_margin_cents" => "650",
        "stockout_cost_cents" => "1200", "holding_cost_cents" => "40",
    ))
    @test created.sku_code == "SKU-GOLD"
    @test get_sku(store, BATCH012_PLANNER_A, created.id).unit_margin_cents == 650

    red_id = "30000000-0000-4000-8000-000000000001"
    updated = InventoryAllocationSimulator._apply_sku_ui_form!(store, BATCH012_PLANNER_A, Dict(
        "name" => "Red Widget Plus", "category" => "premium-widgets",
        "unit_volume" => "1.5", "unit_margin_cents" => "800",
        "stockout_cost_cents" => "1600", "holding_cost_cents" => "55",
    ); sku_id = red_id)
    @test updated.name == "Red Widget Plus"
    deactivated = InventoryAllocationSimulator._apply_sku_ui_form!(store, BATCH012_PLANNER_A, Dict("active" => "false"); sku_id = red_id)
    @test deactivated.active == false

    @test_throws AuthzError InventoryAllocationSimulator._apply_sku_ui_form!(store, BATCH012_VIEWER_A, Dict("active" => "false"); sku_id = red_id)

    viewer_html = render_skus_page(store, BATCH012_VIEWER_A)
    @test occursin("Permission required to change SKUs", viewer_html)
    @test !occursin("Deactivate SKU-RED", viewer_html)
end
