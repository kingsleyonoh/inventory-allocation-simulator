using Genie.Router
using Genie.Renderer: respond
using HTTP
using JSON3

include("routes_definitions.jl")
include("routes_health.jl")
include("routes_ui.jl")
include("routes_api.jl")

# Source-contract sentinel for scaffold tests: /health is registered by register_health_routes!.
function register_routes!(services::Union{Nothing,AppServices} = nothing)
    register_health_routes!(services)
    if services !== nothing
        register_ui_routes!(services)
        register_api_routes!(services)
    end
    return route_definitions()
end
