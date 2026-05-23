using LibPQ

mutable struct DBService
    url::String
    connection::Union{Nothing,LibPQ.Connection}
end

DBService(url::AbstractString) = DBService(String(url), nothing)

function connect!(service::DBService)::LibPQ.Connection
    if service.connection === nothing
        service.connection = LibPQ.Connection(service.url)
    end
    return service.connection::LibPQ.Connection
end

function close!(service::DBService)::Nothing
    if service.connection !== nothing
        close(service.connection::LibPQ.Connection)
        service.connection = nothing
    end
    return nothing
end

struct CacheService
    url::String
end

struct AnalyticsService
    path::String
end
