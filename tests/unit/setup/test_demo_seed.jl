using Test

@testset "Demo CSV fixtures validate through production seed helper" begin
    manifest = InventoryAllocationSimulator.validate_demo_fixtures(joinpath(InventoryAllocationSimulator.project_root(), "tests", "fixtures", "csv"))

    @test manifest.valid == true
    @test manifest.row_counts["warehouses.csv"] >= 2
    @test manifest.row_counts["skus.csv"] >= 2
    @test manifest.row_counts["inventory.csv"] >= 2
    @test manifest.row_counts["demand_history.csv"] >= 4
    @test manifest.row_counts["transfer_lanes.csv"] >= 2
end

@testset "Demo CSV fixture validation fails loudly for missing required files" begin
    mktempdir() do dir
        @test_throws ArgumentError InventoryAllocationSimulator.validate_demo_fixtures(dir)
    end
end
