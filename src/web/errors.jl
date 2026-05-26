using Dates
using JSON3

struct ApiError <: Exception
    code::String
    message::String
    status::Int
    details::Vector{Any}
end

function ApiError(
    code::AbstractString,
    message::AbstractString;
    status::Int = 400,
    details::Vector{<:Any} = Any[],
)::ApiError
    100 <= status <= 599 || throw(ArgumentError("HTTP status must be between 100 and 599"))
    return ApiError(String(code), String(message), status, Any[details...])
end

function Base.showerror(io::IO, err::ApiError)
    print(io, err.code, ": ", err.message)
end

function format_error_response(
    code::AbstractString,
    message::AbstractString;
    details = Any[],
    request_id::Union{Nothing,AbstractString} = nothing,
)
    if request_id === nothing
        return (error = (code = String(code), message = String(message), details = details),)
    end
    error = Dict{String,Any}("code" => String(code), "message" => String(message), "details" => details, "request_id" => String(request_id))
    return Dict("error" => error)
end

function endpoint_error_response(err; request_id::Union{Nothing,AbstractString} = nothing)
    headers = Dict{String,String}()
    request_id !== nothing && (headers["X-Request-ID"] = String(request_id))
    if err isa ApiError
        body = format_error_response(err.code, err.message; details = err.details, request_id = request_id)
        return request_id === nothing ? (err.status, JSON3.write(body)) : (err.status, JSON3.write(body), headers)
    end
    body = format_error_response("INTERNAL_ERROR", "An unexpected error occurred"; details = Any[], request_id = request_id)
    return request_id === nothing ? (500, JSON3.write(body)) : (500, JSON3.write(body), headers)
end
