using Test
using InventoryAllocationSimulator
using Aqua

const TEST_ROOT = @__DIR__
const requested = Set(string.(ARGS))

function include_if_requested(kind::String, path::String)
    if isempty(requested) || kind in requested
        include(path)
    end
end

@testset "Inventory Allocation Simulator" begin
    include_if_requested("unit", joinpath(TEST_ROOT, "unit", "setup", "test_project_scaffold.jl"))
    if isempty(requested) || "aqua" in requested
        @testset "Aqua quality checks" begin
            Aqua.test_all(InventoryAllocationSimulator; stale_deps = false)
        end
    end
end
