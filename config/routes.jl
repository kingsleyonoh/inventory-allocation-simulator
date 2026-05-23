using Genie.Router
using JSON3

struct RouteDefinition
    method::Symbol
    path::String
    name::String
end

function route_definitions()::Vector{RouteDefinition}
    return [RouteDefinition(:GET, "/health", "health")]
end

health_response() = (status = "ok", service = "inventory-allocation-simulator")

function register_routes!(services::Union{Nothing,AppServices} = nothing)
    route("/health") do
        JSON3.write(health_response())
    end

    return route_definitions()
end
