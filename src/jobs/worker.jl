mutable struct JobService
    configured::Bool
    queues::Vector{String}
    running::Bool
    shutdown_requested::Bool
    worker_tasks::Vector{Task}
    import_store::Union{Nothing,AbstractTenantAdminStore}
    import_config::Union{Nothing,AppConfig}
    import_contexts::Vector{TenantContext}
    simulation_store::Union{Nothing,AbstractTenantAdminStore}
    simulation_contexts::Vector{TenantContext}
    last_backtest_run_date::Union{Nothing,Date}
    poll_interval_seconds::Float64
end

function build_job_service()::JobService
    return JobService(true, ["import_job_worker", "simulation_worker", "stale_run_reaper", "daily_backtest", "outbox_dispatcher"], false, false, Task[], nothing, nothing, TenantContext[], nothing, TenantContext[], nothing, 0.05)
end

function import_job_worker!(store::AbstractTenantAdminStore, config::AppConfig, ctx::TenantContext; worker_id::AbstractString = "import-worker")
    claimed = claim_next_import_job!(store, ctx; worker_id = worker_id)
    claimed === nothing && return nothing
    return process_import_job!(store, config, ctx, claimed.id)
end

function import_job_worker!(store::SqlTenantAdminStore, config::AppConfig; worker_id::AbstractString = "import-worker")
    claimed = claim_next_import_job_for_system!(store; worker_id = worker_id)
    claimed === nothing && return nothing
    ctx = TenantContext(claimed.tenant_id; role = "admin", auth_method = :job)
    return process_import_job!(store, config, ctx, claimed.id)
end

function _import_worker(service::JobService)::Nothing
    while !service.shutdown_requested
        if service.import_store isa SqlTenantAdminStore && service.import_config !== nothing
            import_job_worker!(service.import_store, service.import_config; worker_id = "import-worker")
        elseif service.import_store !== nothing && service.import_config !== nothing
            for ctx in service.import_contexts
                service.shutdown_requested && break
                import_job_worker!(service.import_store, service.import_config, ctx; worker_id = "import-worker")
            end
        end
        sleep(service.poll_interval_seconds)
    end
    return nothing
end

function run_due_daily_backtest!(
    service::JobService,
    store::AbstractTenantAdminStore,
    config::AppConfig,
    contexts::AbstractVector{TenantContext};
    now::DateTime = Dates.now(),
)::NamedTuple
    daily_backtest_due(now, service.last_backtest_run_date) || return (ran = false, results_written = 0, reports = NamedTuple[])
    reports = if store isa SqlTenantAdminStore
        run_daily_backtests!(store, config; as_of = now)
    else
        run_daily_backtests!(store, config, contexts; as_of = now)
    end
    service.last_backtest_run_date = Date(now)
    return (ran = true, results_written = length(reports), reports = reports)
end

function _simulation_worker(service::JobService)::Nothing
    while !service.shutdown_requested
        if service.simulation_store isa SqlTenantAdminStore && service.import_config !== nothing
            simulation_worker!(service.simulation_store, service.import_config; worker_id = "simulation-worker")
            reap_stale_simulation_runs!(service.simulation_store, service.import_config)
            run_due_daily_backtest!(service, service.simulation_store, service.import_config, TenantContext[])
        elseif service.simulation_store !== nothing && service.import_config !== nothing
            for ctx in service.simulation_contexts
                service.shutdown_requested && break
                simulation_worker!(service.simulation_store, ctx; worker_id = "simulation-worker")
                reap_stale_simulation_runs!(service.simulation_store, ctx; stale_after_minutes = service.import_config.simulation.run_stale_after_minutes)
            end
            run_due_daily_backtest!(service, service.simulation_store, service.import_config, service.simulation_contexts)
        end
        sleep(service.poll_interval_seconds)
    end
    return nothing
end

function _idle_worker(service::JobService)::Nothing
    while !service.shutdown_requested
        sleep(service.poll_interval_seconds)
    end
    return nothing
end

function start!(
    service::JobService;
    worker_count::Int = 0,
    import_store::Union{Nothing,AbstractTenantAdminStore} = nothing,
    import_config::Union{Nothing,AppConfig} = nothing,
    import_contexts::AbstractVector{TenantContext} = TenantContext[],
    simulation_store::Union{Nothing,AbstractTenantAdminStore} = import_store,
    simulation_contexts::AbstractVector{TenantContext} = import_contexts,
)::JobService
    service.shutdown_requested = false
    service.running = true
    service.import_store = import_store
    service.import_config = import_config
    service.import_contexts = collect(import_contexts)
    service.simulation_store = simulation_store
    service.simulation_contexts = collect(simulation_contexts)
    empty!(service.worker_tasks)
    if import_store isa SqlTenantAdminStore && import_config !== nothing
        push!(service.worker_tasks, @async _import_worker(service))
    elseif import_store !== nothing && import_config !== nothing && !isempty(import_contexts)
        push!(service.worker_tasks, @async _import_worker(service))
    end
    if simulation_store isa SqlTenantAdminStore && import_config !== nothing
        push!(service.worker_tasks, @async _simulation_worker(service))
    elseif simulation_store !== nothing && import_config !== nothing && !isempty(simulation_contexts)
        push!(service.worker_tasks, @async _simulation_worker(service))
    end
    for _ in 1:worker_count
        push!(service.worker_tasks, @async _idle_worker(service))
    end
    return service
end

function stop!(service::JobService; timeout_seconds::Real = 5)::JobService
    service.shutdown_requested = true
    deadline = time() + Float64(timeout_seconds)
    for task in service.worker_tasks
        while !istaskdone(task) && time() < deadline
            sleep(0.01)
        end
        if !istaskdone(task)
            Base.throwto(task, InterruptException())
        end
    end
    empty!(service.worker_tasks)
    service.running = false
    return service
end

function close!(service::JobService)::Nothing
    stop!(service)
    return nothing
end
