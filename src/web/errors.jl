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
)
    return (error = (code = String(code), message = String(message), details = details),)
end

function endpoint_error_response(err)::Tuple{Int,String}
    if err isa ApiError
        body = format_error_response(err.code, err.message; details = err.details)
        return err.status, JSON3.write(body)
    end
    body = format_error_response("INTERNAL_ERROR", "An unexpected error occurred"; details = Any[])
    return 500, JSON3.write(body)
end
