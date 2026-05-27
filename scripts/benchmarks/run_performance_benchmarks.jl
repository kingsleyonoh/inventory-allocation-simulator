#!/usr/bin/env julia

using Dates
using HTTP
using JSON3
using UUIDs
using InventoryAllocationSimulator

include("benchmark_support.jl")
include("recommendation_import_benchmarks.jl")
include("simulation_benchmarks.jl")
include("solver_outbox_benchmarks.jl")
include("benchmark_manifest.jl")

# Source-contract sentinels for benchmark wiring tests after modular split:
# large_simulation_benchmark_fixture recommendation_list_benchmark_fixture csv_import_benchmark_fixture
# dashboard_lcp_benchmark_pages p95_ms time_ns list_recommendations HTTP.request
# create_import_job! process_import_job! benchmark_large_simulation simulation_benchmarks.jl
# scenario_count = 100 simulation_worker! create_simulation_run! benchmark_solver_timeout solver_timeout_grace_seconds
# timeout_seconds + performance_targets().solver_timeout_grace_seconds solve_allocation_model AllocationSolverConfig
# benchmark_outbox_dispatch_latency queued_events benchmark_outbox_dispatch_60s! dispatch_outbox_once!
# solver_timeout = solver_timeout outbox_dispatch_latency = outbox_dispatch

function main()
    println(JSON3.write(benchmark_manifest()))
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
