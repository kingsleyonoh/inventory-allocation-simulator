mutable struct JobService
    configured::Bool
    queues::Vector{String}
    running::Bool
    shutdown_requested::Bool
    worker_tasks::Vector{Task}
    import_store::Union{Nothing,AbstractTenantAdminStore}
    import_config::Union{Nothing,AppConfig}
    import_contexts::Vector{TenantContext}
    poll_interval_seconds::Float64
end

function build_job_service()::JobService
    return JobService(true, ["import_job_worker", "simulation_worker", "outbox_dispatcher"], false, false, Task[], nothing, nothing, TenantContext[], 0.05)
end

function import_job_worker!(store::AbstractTenantAdminStore, config::AppConfig, ctx::TenantContext; worker_id::AbstractString = "import-worker")
    claimed = claim_next_import_job!(store, ctx; worker_id = worker_id)
    claimed === nothing && return nothing
    return process_import_job!(store, config, ctx, claimed.id)
end

function import_job_worker!(store::SqlTenantAdminStore, config::AppConfig; worker_id::AbstractString = "import-worker")
    claimed = claim_next_import_job!(store; worker_id = worker_id)
    claimed === nothing && return nothing
    return process_import_job!(store, config, claimed.id)
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
)::JobService
    service.shutdown_requested = false
    service.running = true
    service.import_store = import_store
    service.import_config = import_config
    service.import_contexts = collect(import_contexts)
    empty!(service.worker_tasks)
    if import_store isa SqlTenantAdminStore && import_config !== nothing
        push!(service.worker_tasks, @async _import_worker(service))
    elseif import_store !== nothing && import_config !== nothing && !isempty(import_contexts)
        push!(service.worker_tasks, @async _import_worker(service))
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
