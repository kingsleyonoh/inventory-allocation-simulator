@testset "Batch 054 solver timeout and infeasible failures are readable failed simulation runs" begin
    timeout_store, timeout_policy_id = batch020_worker_store()
    timeout_run = create_simulation_run!(
        timeout_store,
        BATCH012_PLANNER_A,
        Dict("policy_id" => timeout_policy_id, "name" => "Timeout solver worker", "scenario_count" => 1),
    )

    timeout_completed = simulation_worker!(
        timeout_store,
        BATCH012_ADMIN_A;
        worker_id = "worker-054-timeout",
        seed = 1,
        solver_config = AllocationSolverConfig(timeout_seconds = 0.0, max_gap = 0.05, min_transfer_units = 1.0),
    )

    @test timeout_completed.id == timeout_run.id
    @test timeout_completed.status == "failed"
    @test occursin("SOLVER_FAILED", timeout_completed.error_message)
    @test occursin("TIME_LIMIT", timeout_completed.error_message)
    @test occursin("timeout", lowercase(timeout_completed.error_message))
    @test occursin("constraint_report", timeout_completed.error_message)
    @test occursin("sender safety stock", timeout_completed.error_message)
    @test isempty([row for row in values(timeout_store.allocation_recommendations) if row[:simulation_run_id] == UUID(timeout_run.id)])

    persisted_timeout = get_simulation_run(timeout_store, BATCH012_PLANNER_A, timeout_run.id)
    @test persisted_timeout.status == "failed"
    @test persisted_timeout.error_message == timeout_completed.error_message

    infeasible_store, infeasible_policy_id = batch020_worker_store()
    infeasible_store.allocation_policies[UUID(infeasible_policy_id)][:max_transfer_cost_cents] = 1_000
    infeasible_run = create_simulation_run!(
        infeasible_store,
        BATCH012_PLANNER_A,
        Dict("policy_id" => infeasible_policy_id, "name" => "Infeasible solver worker", "scenario_count" => 1),
    )

    infeasible_completed = simulation_worker!(infeasible_store, BATCH012_ADMIN_A; worker_id = "worker-054-infeasible", seed = 1)

    @test infeasible_completed.id == infeasible_run.id
    @test infeasible_completed.status == "failed"
    @test occursin("SOLVER_FAILED", infeasible_completed.error_message)
    @test occursin("INFEASIBLE", infeasible_completed.error_message)
    @test occursin("constraint_report", infeasible_completed.error_message)
    @test occursin("max_transfer_cost_cents=1000", infeasible_completed.error_message)
    @test occursin("sender safety stock", infeasible_completed.error_message)
    @test isempty([row for row in values(infeasible_store.allocation_recommendations) if row[:simulation_run_id] == UUID(infeasible_run.id)])
end

@testset "Batch 054 solver failure audit gate is wired to production sources" begin
    script = joinpath(project_root(), ".yolo", "scripts", "validate-batch-054-solver-failure-audit.sh")
    @test isfile(script)
    script_source = read(script, String)
    @test occursin("test_batch054_solver_failure_audit.jl", script_source)
    @test occursin("solver_config = AllocationSolverConfig", script_source)
    @test occursin("TIME_LIMIT", script_source)
    @test occursin("INFEASIBLE", script_source)
    @test occursin("_simulation_failure_message", script_source)
end
