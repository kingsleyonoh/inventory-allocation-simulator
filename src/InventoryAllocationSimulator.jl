module InventoryAllocationSimulator

using Genie

export main, run_server!, register_routes!, parse_port

include("../config/routes.jl")

const DEFAULT_HOST = "0.0.0.0"
const DEFAULT_PORT = 8000

function parse_port(value::AbstractString)::Int
    port = tryparse(Int, value)
    if port === nothing || port < 1 || port > 65535
        throw(ArgumentError("APP_PORT must be an integer from 1 to 65535"))
    end
    return port
end

function run_server!(; host::AbstractString = get(ENV, "APP_HOST", DEFAULT_HOST),
                     port::Int = parse_port(get(ENV, "APP_PORT", string(DEFAULT_PORT))),
                     async::Bool = false)
    register_routes!()
    Genie.up(port, host; async = async)
    return nothing
end

function main()
    run_server!()
    return nothing
end

end # module
