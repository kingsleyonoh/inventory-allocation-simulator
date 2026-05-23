using Test
using InventoryAllocationSimulator
using Aqua

const TEST_ROOT = @__DIR__
const requested = Set(string.(ARGS))

function include_tree(kind::String, path::String)
    if isempty(requested) || kind in requested
        for (root, _dirs, files) in walkdir(path)
            for file in sort(filter(name -> endswith(name, ".jl"), files))
                include(joinpath(root, file))
            end
        end
    end
end

@testset "Inventory Allocation Simulator" begin
    include_tree("unit", joinpath(TEST_ROOT, "unit"))
    include_tree("integration", joinpath(TEST_ROOT, "integration"))
    if isempty(requested) || "aqua" in requested
        @testset "Aqua quality checks" begin
            Aqua.test_all(InventoryAllocationSimulator; stale_deps = false)
        end
    end
end
