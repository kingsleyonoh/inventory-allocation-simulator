using HTTP
using JSON3

function integration_http_post(url::AbstractString, body::AbstractDict, headers::AbstractDict; timeout_seconds::Real = 10)
    response = HTTP.post(String(url), collect(Pair{String,String}.(string.(keys(headers)), string.(values(headers)))); body = JSON3.write(body), readtimeout = Float64(timeout_seconds))
    return (status = response.status, body = String(response.body))
end

function _join_url(base::AbstractString, path::AbstractString)::String
    clean_base = rstrip(String(base), '/')
    clean_path = startswith(String(path), "/") ? String(path) : "/$(path)"
    return "$(clean_base)$(clean_path)"
end

function _enabled_url!(enabled::Bool, url::AbstractString, adapter::AbstractString)::String
    enabled || throw(ApiError("ADAPTER_DISABLED", "$(adapter) is disabled"; status = 409))
    isempty(strip(String(url))) && throw(ApiError("VALIDATION_ERROR", "$(adapter) URL is required when enabled"; status = 400))
    return String(url)
end

function _enabled_key!(enabled::Bool, key::AbstractString, adapter::AbstractString)::String
    enabled || throw(ApiError("ADAPTER_DISABLED", "$(adapter) is disabled"; status = 409))
    isempty(strip(String(key))) && throw(ApiError("VALIDATION_ERROR", "$(adapter) API key is required when enabled"; status = 400))
    return String(key)
end
