struct JobService
    configured::Bool
    queues::Vector{String}
end

function build_job_service()::JobService
    return JobService(true, ["import_job_worker", "simulation_worker", "outbox_dispatcher"])
end
