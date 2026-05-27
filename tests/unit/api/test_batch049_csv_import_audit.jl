using Test
using InventoryAllocationSimulator

function batch049_inventory_csv(; corrected::Bool = false)
    rows = corrected ? [
        "warehouse_code,sku_code,on_hand_units,reserved_units,inbound_units,safety_stock_units,source",
        "BRI,SKU-RED,11,0,0,2,csv",
        "EDI,SKU-BLUE,6,1,0,1,csv",
    ] : [
        "warehouse_code,sku_code,on_hand_units,reserved_units,inbound_units,safety_stock_units,source",
        "BRI,SKU-RED,10,0,0,2,csv",
        "EDI,SKU-BLUE,5,1,0,1,csv",
        "BRI,SKU-MISSING,8,0,0,0,csv",
        "EDI,SKU-RED,-1,0,0,0,csv",
    ]
    return join(rows, "\n")
end

@testset "Batch 049 CSV imports expose row-level validation errors through the result surface" begin
    store = batch012_store()
    config = batch014_config(partial_commit = false, upload_storage_path = mktempdir())
    job = create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", "inventory-audit.csv", batch049_inventory_csv())

    result = import_job_worker!(store, config, BATCH012_PLANNER_A; worker_id = "worker-049")
    fetched = get_import_result(store, BATCH012_VIEWER_A, job.id)

    @test result.status == "failed"
    @test fetched.status == "failed"
    @test result.committed_rows == 0
    @test fetched.committed_rows == 0
    @test result.row_count == 4
    @test isfile(fetched.file_path)
    @test read(fetched.file_path, String) == batch049_inventory_csv()
    @test Set(error.row for error in fetched.error_report) == Set([4, 5])
    @test Set(error.code for error in fetched.error_report) == Set(["UNKNOWN_SKU", "NEGATIVE_INVENTORY"])
    @test any(error -> error.field == "sku_code" && occursin("tenant SKU", error.message), fetched.error_report)
    @test any(error -> error.field == "on_hand_units" && occursin("non-negative", error.message), fetched.error_report)

    bri_red = first(filter(row -> row.warehouse_id == "10000000-0000-4000-8000-000000000001" && row.sku_id == "30000000-0000-4000-8000-000000000001", list_inventory_positions(store, BATCH012_VIEWER_A).inventory))
    @test bri_red.on_hand_units == 100.0
    @test_throws ApiError get_import_result(store, BATCH012_ADMIN_B, job.id)
end

@testset "Batch 049 CSV imports support queued retry from preserved upload artifacts" begin
    store = batch012_store()
    config = batch014_config(partial_commit = false, upload_storage_path = mktempdir())
    failed_job = create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", "inventory-bad.csv", batch049_inventory_csv())
    failed = import_job_worker!(store, config, BATCH012_PLANNER_A; worker_id = "worker-049-first")
    @test failed.status == "failed"
    @test !isempty(get_import_result(store, BATCH012_VIEWER_A, failed_job.id).error_report)

    retry_job = create_import_job!(store, config, BATCH012_PLANNER_A, "inventory", "inventory-corrected.csv", batch049_inventory_csv(corrected = true))
    @test retry_job.status == "queued"
    @test retry_job.import_type == failed.import_type
    @test retry_job.original_filename == "inventory-corrected.csv"
    @test isfile(retry_job.file_path)
    @test read(retry_job.file_path, String) == batch049_inventory_csv(corrected = true)

    retry_result = import_job_worker!(store, config, BATCH012_PLANNER_A; worker_id = "worker-049-retry")
    @test retry_result.id == retry_job.id
    @test retry_result.status == "completed"
    @test isempty(retry_result.error_report)
    @test retry_result.committed_rows == 2

    bri_red = first(filter(row -> row.warehouse_id == "10000000-0000-4000-8000-000000000001" && row.sku_id == "30000000-0000-4000-8000-000000000001", list_inventory_positions(store, BATCH012_VIEWER_A).inventory))
    edi_blue = first(filter(row -> row.warehouse_id == "10000000-0000-4000-8000-000000000002" && row.sku_id == "30000000-0000-4000-8000-000000000002", list_inventory_positions(store, BATCH012_VIEWER_A).inventory))
    @test bri_red.on_hand_units == 11.0
    @test edi_blue.on_hand_units == 6.0
end

@testset "Batch 049 CSV import audit gate is rerunnable" begin
    script = joinpath(project_root(), ".yolo", "scripts", "validate-batch-049-csv-import-audit.sh")
    @test isfile(script)
    isfile(script) || return
    source = read(script, String)
    for token in ["CSV_IMPORT_ROW_ERRORS_AND_RETRY_AUDIT", "error_report", "file_path", "import_job_worker!", "claim_next_import_job_for_system!"]
        @test occursin(token, source)
    end
end
