mutable struct JobService
    configured::Bool
    queues::Vector{String}
    running::Bool
    shutdown_requested::Bool
    worker_tasks::Vector{Task}
end

function build_job_service()::JobService
    return JobService(true, ["import_job_worker", "simulation_worker", "outbox_dispatcher"], false, false, Task[])
end

function _idle_worker(service::JobService)::Nothing
    while !service.shutdown_requested
        sleep(0.05)
    end
    return nothing
end

function start!(service::JobService; worker_count::Int = 0)::JobService
    service.shutdown_requested = false
    service.running = true
    empty!(service.worker_tasks)
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
