using Dates
using JSON3
using UUIDs

struct ObservabilityService
    log_level::String
    metrics_token::String
    sentry_dsn::String
end

function build_observability_service(config::ObservabilityConfig)::ObservabilityService
    return ObservabilityService(config.metrics_token == "" ? "info" : get(ENV, "LOG_LEVEL", "info"), config.metrics_token, config.sentry_dsn)
end

function request_id_from_headers(headers::AbstractDict)::String
    for key in ("X-Request-ID", "x-request-id", "X-Correlation-ID", "x-correlation-id")
        value = get(headers, key, nothing)
        if value !== nothing && !isempty(strip(String(value)))
            return String(value)
        end
    end
    return "req_$(replace(string(uuid4()), "-" => ""))"
end

function _safe_log_fields(fields::AbstractDict)::Dict{String,Any}
    safe = Dict{String,Any}()
    for (key, value) in fields
        name = lowercase(String(key))
        if occursin("key", name) || occursin("token", name) || occursin("secret", name) || occursin("password", name)
            continue
        end
        safe[String(key)] = value
    end
    return safe
end

function structured_log_json(
    level::AbstractString,
    message::AbstractString;
    request_id::Union{Nothing,AbstractString} = nothing,
    log_module::AbstractString = "app",
    tenant_id::Union{Nothing,AbstractString} = nothing,
    fields::AbstractDict = Dict{String,Any}(),
)::String
    payload = Dict{String,Any}(
        "timestamp" => string(Dates.now()),
        "level" => lowercase(String(level)),
        "message" => String(message),
        "module" => String(log_module),
        "request_id" => request_id === nothing ? request_id_from_headers(Dict{String,String}()) : String(request_id),
    )
    tenant_id !== nothing && (payload["tenant_id"] = String(tenant_id))
    merge!(payload, _safe_log_fields(fields))
    return JSON3.write(payload)
end
