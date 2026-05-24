using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

function batch014_config(; partial_commit::Bool = false, upload_storage_path::String = mktempdir(), max_import_mb::Int = 25)
    return InventoryAllocationSimulator.load_config(Dict(
        "DATABASE_URL" => raw"postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/inventory_allocation",
        "REDIS_URL" => "redis://localhost:6379/0",
        "DUCKDB_PATH" => "./data/test-batch014.duckdb",
        "SESSION_SECRET" => "batch014-session-secret-placeholder",
        "METRICS_TOKEN" => "batch014-metrics-token-placeholder",
        "SELF_REGISTRATION_ENABLED" => "true",
        "API_KEY_PREFIX" => "ias_test",
        "DEFAULT_ADMIN_EMAIL" => "admin@example.test",
        "IMPORT_PARTIAL_COMMIT" => string(partial_commit),
        "UPLOAD_STORAGE_PATH" => upload_storage_path,
        "MAX_IMPORT_MB" => string(max_import_mb),
    ))
end

function batch014_inventory_csv()
    return join([
        "warehouse_code,sku_code,on_hand_units,reserved_units,inbound_units,safety_stock_units,source",
        "BRI,SKU-RED,10,0,0,2,csv",
        "EDI,SKU-BLUE,5,1,0,1,csv",
        "BRI,SKU-MISSING,8,0,0,0,csv",
        "EDI,SKU-RED,-1,0,0,0,csv",
    ], "\n")
end

function batch014_warehouses_csv()
    return join([
        "code,name,region,capacity_units,handling_cost_cents",
        "MAN,Manchester DC,GB-NW,3000,9",
        "BAD,Bad Capacity,GB-NW,not-a-number,1",
    ], "\n")
end

@testset "Batch 014 policy import and snapshot API surfaces are wired" begin
    definitions = route_definitions()
    expected = Set([
        (:GET, "/api/policies"),
        (:POST, "/api/policies"),
        (:POST, "/api/imports"),
        (:GET, "/api/imports/:id"),
    ])
    actual = Set((def.method, def.path) for def in definitions)
    @test issubset(expected, actual)

    controller = read(joinpath(project_root(), "src", "web", "controllers", "planning_catalog_controller.jl"), String)
    for handler in ["handle_list_policies", "handle_create_policy", "handle_create_import", "handle_get_import_result"]
        handler_start = findfirst("function $handler", controller)
        @test handler_start !== nothing
        next_handler = findnext("function ", controller, last(handler_start) + 1)
        block = next_handler === nothing ? controller[first(handler_start):end] : controller[first(handler_start):first(next_handler)-1]
        @test occursin("_enforce_route_rate_limit!", block)
        @test occursin("_protected_context_and_store", block)
    end
end

@testset "Policy endpoints use policy authorization and validation" begin
    store = batch012_store()

    listed = list_allocation_policies(store, BATCH012_VIEWER_A; params = Dict("status" => "active")).policies
    @test [policy.name for policy in listed] == ["Balanced baseline"]

    created = create_allocation_policy!(store, BATCH012_PLANNER_A, Dict(
        "name" => "Batch 014 balanced",
        "objective" => "balanced",
        "planning_horizon_days" => 14,
        "service_level_target" => 0.9,
        "status" => "draft",
    ))
    @test created.tenant_id == string(BATCH012_TENANT_A)
    @test_throws AuthzError create_allocation_policy!(store, BATCH012_VIEWER_A, Dict("name" => "Denied", "objective" => "balanced", "planning_horizon_days" => 14, "service_level_target" => 0.9, "status" => "draft"))
    @test_throws ApiError create_allocation_policy!(store, BATCH012_PLANNER_A, Dict("name" => "Bad", "objective" => "balanced", "planning_horizon_days" => 0, "service_level_target" => 0.9, "status" => "draft"))
end

@testset "Simulation input snapshot freezes current tenant planning data" begin
    store = batch012_store()
    policy_id = UUID("b0000000-0000-4000-8000-000000000001")

    snapshot = capture_simulation_input_snapshot(store, BATCH012_PLANNER_A, policy_id)
    @test snapshot.policy.name == "Balanced baseline"
    @test [row.code for row in snapshot.warehouses] == ["BRI", "EDI"]
    @test [row.sku_code for row in snapshot.skus] == ["SKU-BLUE", "SKU-RED"]
    @test length(snapshot.inventory_positions) == 2
    @test !occursin("Kōwhai", JSON3.write(snapshot))

    store.warehouses[UUID("10000000-0000-4000-8000-000000000001")][:name] = "MUTATED AFTER SNAPSHOT"
    store.inventory_positions[UUID("50000000-0000-4000-8000-000000000001")][:on_hand_units] = 9999.0
    @test first(filter(row -> row.code == "BRI", snapshot.warehouses)).name == "Bristol DC"
    @test first(filter(row -> row.sku_id == "30000000-0000-4000-8000-000000000001", snapshot.inventory_positions)).on_hand_units == 100.0

    @test_throws AuthzError capture_simulation_input_snapshot(store, BATCH012_VIEWER_A, policy_id)
    @test_throws ApiError capture_simulation_input_snapshot(store, BATCH012_PLANNER_A, UUID("c0000000-0000-4000-8000-000000000001"))
end

@testset "Simulation snapshots include more than one API page of tenant data" begin
    store = batch012_store()
    for idx in 1:260
        id = uuid4()
        store.skus[id] = Dict{Symbol,Any}(
            :id => id,
            :tenant_id => BATCH012_TENANT_A,
            :sku_code => lpad("SKU-BULK-$idx", 16, '0'),
            :name => "Bulk SKU $idx",
            :category => "bulk",
            :unit_volume => 1.0,
            :unit_margin_cents => 1,
            :stockout_cost_cents => 1,
            :holding_cost_cents => 1,
            :active => true,
        )
    end

    snapshot = capture_simulation_input_snapshot(store, BATCH012_PLANNER_A, UUID("b0000000-0000-4000-8000-000000000001"))
    @test length(snapshot.skus) == 262
end

@testset "CSV import jobs persist artifacts and support worker claims" begin
    store = batch012_store()
    config = batch014_config(upload_storage_path = mktempdir())

    job = create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", "inventory-mixed.csv", batch014_inventory_csv())
    @test job.status == "queued"
    @test job.import_type == "inventory"
    @test job.row_count == 4
    @test isfile(job.file_path)
    @test read(job.file_path, String) == batch014_inventory_csv()

    claimed = claim_next_import_job!(store, BATCH012_PLANNER_A; worker_id = "worker-014")
    @test claimed.id == job.id
    @test claimed.status == "running"
    @test get_import_result(store, BATCH012_VIEWER_A, job.id).status == "running"
    @test_throws ApiError get_import_result(store, BATCH012_ADMIN_B, job.id)
    @test_throws AuthzError create_import_job!(store, config, BATCH012_VIEWER_A, "inventory", "blocked.csv", batch014_inventory_csv())
end

@testset "Import worker and API contracts are wired to production paths" begin
    controller = read(joinpath(project_root(), "src", "web", "controllers", "planning_catalog_controller.jl"), String)
    entrypoint = read(joinpath(project_root(), "src", "InventoryAllocationSimulator.jl"), String)

    validate_inventory = getfield(InventoryAllocationSimulator, Symbol("_validate_inventory_import_row"))
    with_transaction = getfield(InventoryAllocationSimulator, Symbol("_with_import_transaction!"))
    importer_source = read(joinpath(project_root(), "src", "imports", "importer.jl"), String)
    system_claim_name = Symbol("claim_next_import_job_for_system!")
    @test hasmethod(validate_inventory, Tuple{InventoryAllocationSimulator.SqlTenantAdminStore, UUID, Int, Dict{String,String}})
    @test hasmethod(with_transaction, Tuple{InventoryAllocationSimulator.SqlTenantAdminStore, Function})
    @test isdefined(InventoryAllocationSimulator, system_claim_name)
    if isdefined(InventoryAllocationSimulator, system_claim_name)
        system_claim = getfield(InventoryAllocationSimulator, system_claim_name)
        @test hasmethod(system_claim, Tuple{InventoryAllocationSimulator.SqlTenantAdminStore})
    end
    @test !hasmethod(InventoryAllocationSimulator.claim_next_import_job!, Tuple{InventoryAllocationSimulator.SqlTenantAdminStore})
    @test !hasmethod(InventoryAllocationSimulator.process_import_job!, Tuple{InventoryAllocationSimulator.SqlTenantAdminStore, AppConfig, UUID})
    @test !occursin("function _fetch_import_job_by_id", importer_source)
    system_claim_start = findfirst("function claim_next_import_job_for_system!", importer_source)
    @test system_claim_start !== nothing
    if system_claim_start !== nothing
        next_function = findnext("function ", importer_source, last(system_claim_start) + 1)
        system_claim_block = next_function === nothing ? importer_source[first(system_claim_start):end] : importer_source[first(system_claim_start):first(next_function)-1]
        @test occursin("RETURNING id, tenant_id", system_claim_block)
        @test !occursin("file_path", system_claim_block)
        @test !occursin("error_report", system_claim_block)
    end
    @test with_transaction(batch012_store(), () -> :memory_transaction_passthrough) == :memory_transaction_passthrough
    @test occursin("filespayload", controller)
    @test occursin("postpayload", controller)
    @test !occursin("payload = _json_body()", controller)
    @test occursin("start_runtime_jobs!", entrypoint)
end

@testset "run_server start_jobs entrypoint wires import worker dependencies" begin
    config = batch014_config(upload_storage_path = mktempdir())
    store = batch012_store()
    started = Ref(false)
    server_starter = function (port, host; async = false)
        @test port == config.app.port
        @test host == config.app.host
        @test async == true
        started[] = true
        return nothing
    end

    services = run_server!(
        config = config,
        async = true,
        start_jobs = true,
        import_store = store,
        server_starter = server_starter,
        install_hook = false,
    )
    try
        @test started[]
        @test services.jobs.running
        @test services.jobs.import_store === store
        @test services.jobs.import_config === config
    finally
        shutdown!(services; stop_http = false)
    end
end

@testset "CSV import jobs reject oversized artifacts" begin
    store = batch012_store()
    config = batch014_config(upload_storage_path = mktempdir(), max_import_mb = 1)
    oversized = "warehouse_code,sku_code,on_hand_units\n" * repeat("BRI,SKU-RED,1\n", 90_000)
    @test sizeof(oversized) > config.imports.max_import_mb * 1024 * 1024
    @test_throws ApiError create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", "too-large.csv", oversized)
end

@testset "Non-inventory CSV imports commit valid rows and report row-level errors" begin
    store = batch012_store()
    config = batch014_config(partial_commit = true, upload_storage_path = mktempdir())
    job = create_import_job!(store, config, BATCH012_PLANNER_A, "warehouses", "warehouses.csv", batch014_warehouses_csv())
    claim_next_import_job!(store, BATCH012_PLANNER_A; worker_id = "worker-014")

    result = process_import_job!(store, config, BATCH012_PLANNER_A, job.id)
    @test result.status == "completed"
    @test result.committed_rows == 1
    @test length(result.error_report) == 1
    @test result.error_report[1].row == 3
    @test result.error_report[1].field == "capacity_units"
    @test get_warehouse(store, BATCH012_VIEWER_A, first(filter(row -> row.code == "MAN", list_warehouses(store, BATCH012_VIEWER_A).warehouses)).id).name == "Manchester DC"
end

@testset "CSV import correctness handles mixed rows and partial commit modes" begin
    for partial in (false, true)
        store = batch012_store()
        config = batch014_config(partial_commit = partial, upload_storage_path = mktempdir())
        job = create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", partial ? "partial.csv" : "all-or-nothing.csv", batch014_inventory_csv())
        claim_next_import_job!(store, BATCH012_PLANNER_A; worker_id = "worker-014")

        result = process_import_job!(store, config, BATCH012_PLANNER_A, job.id)
        errors = result.error_report
        @test length(errors) == 2
        @test Set(error.code for error in errors) == Set(["UNKNOWN_SKU", "NEGATIVE_INVENTORY"])
        @test Set(error.row for error in errors) == Set([4, 5])

        bri_red = first(filter(row -> row.warehouse_id == "10000000-0000-4000-8000-000000000001" && row.sku_id == "30000000-0000-4000-8000-000000000001", list_inventory_positions(store, BATCH012_VIEWER_A).inventory))
        edi_blue = first(filter(row -> row.warehouse_id == "10000000-0000-4000-8000-000000000002" && row.sku_id == "30000000-0000-4000-8000-000000000002", list_inventory_positions(store, BATCH012_VIEWER_A).inventory))

        if partial
            @test result.status == "completed"
            @test result.committed_rows == 2
            @test bri_red.on_hand_units == 10.0
            @test edi_blue.on_hand_units == 5.0
        else
            @test result.status == "failed"
            @test result.committed_rows == 0
            @test bri_red.on_hand_units == 100.0
            @test edi_blue.on_hand_units == 4.0
        end
    end
end
