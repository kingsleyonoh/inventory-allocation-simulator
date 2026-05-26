using Dates
using JSON3

function integration_http_get(url::AbstractString, headers::AbstractDict; timeout_seconds::Real = 10)
    response = HTTP.get(String(url), collect(Pair{String,String}.(string.(keys(headers)), string.(values(headers)))); readtimeout = Float64(timeout_seconds))
    return (status = response.status, body = String(response.body))
end

function _delivery_datetime(value, field::AbstractString)::DateTime
    _is_nullish(value) && throw(ApiError("VALIDATION_ERROR", "Delivery Gateway $(field) is required"; status = 400))
    parsed = try
        DateTime(String(value))
    catch
        nothing
    end
    parsed === nothing && throw(ApiError("VALIDATION_ERROR", "Delivery Gateway $(field) must be an ISO-8601 DateTime"; status = 400))
    return parsed
end

function _delivery_eta_result(payload::AbstractDict; now::DateTime, max_age_minutes::Int = 60)::NamedTuple
    eta_at = _delivery_datetime(get(payload, "eta_at", nothing), "eta_at")
    observed_at = _delivery_datetime(get(payload, "observed_at", nothing), "observed_at")
    minutes_old = max(0, Int(floor(Dates.value(now - observed_at) / 60000)))
    freshness = minutes_old <= max_age_minutes ? "fresh" : "stale"
    return (
        enabled = true,
        status = freshness,
        eta_at = eta_at,
        observed_at = observed_at,
        minutes_old = minutes_old,
        delivery_status = String(get(payload, "status", "unknown")),
    )
end

function delivery_eta_freshness_from_redis_fixture(payload::AbstractDict; now::DateTime = Dates.now(), max_age_minutes::Int = 60)::NamedTuple
    return _delivery_eta_result(Dict{String,Any}(String(k) => v for (k, v) in payload); now = now, max_age_minutes = max_age_minutes)
end

function delivery_eta_freshness(
    config::AppConfig,
    transfer_reference::AbstractString;
    now::DateTime = Dates.now(),
    max_age_minutes::Int = 60,
    http_get::Function = integration_http_get,
)::NamedTuple
    if !config.integrations.delivery_gateway_enabled
        return (enabled = false, status = "disabled", eta_at = nothing, observed_at = nothing, minutes_old = nothing, delivery_status = "disabled")
    end
    base = _enabled_url!(config.integrations.delivery_gateway_enabled, config.integrations.delivery_gateway_url, "Delivery Tracking Gateway")
    key = _enabled_key!(config.integrations.delivery_gateway_enabled, config.integrations.delivery_gateway_api_key, "Delivery Tracking Gateway")
    encoded = HTTP.URIs.escapeuri(String(transfer_reference))
    response = http_get(_join_url(base, "/api/etas/$(encoded)"), Dict("X-API-Key" => key, "Content-Type" => "application/json"); timeout_seconds = 10)
    if !(200 <= Int(response.status) < 300)
        throw(ApiError("ADAPTER_FAILURE", "Delivery Tracking Gateway returned HTTP $(response.status)"; status = 502, details = Any[String(response.body)]))
    end
    payload = JSON3.read(String(response.body))
    return _delivery_eta_result(Dict{String,Any}(String(k) => v for (k, v) in payload); now = now, max_age_minutes = max_age_minutes)
end
