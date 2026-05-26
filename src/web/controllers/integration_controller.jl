function _integration_status_payload(config::AppConfig)::NamedTuple
    statuses = [
        (name = status.name, label = status.label, enabled = status.enabled, status = status.status, detail = status.detail)
        for status in integration_adapter_statuses(config)
    ]
    return (adapters = statuses,)
end

function _requested_adapter_name(payload)::String
    if payload isa AbstractDict
        for key in ("adapter", :adapter)
            haskey(payload, key) && return String(payload[key])
        end
    end
    throw(ApiError("VALIDATION_ERROR", "adapter is required"; status = 400))
end

function _integration_test_payload(config::AppConfig, adapter::AbstractString)::NamedTuple
    statuses = Dict(status.name => status for status in integration_adapter_statuses(config))
    name = String(adapter)
    if !haskey(statuses, name)
        throw(ApiError("VALIDATION_ERROR", "Unknown integration adapter"; status = 400))
    end
    status = statuses[name]
    return (
        adapter = status.name,
        enabled = status.enabled,
        status = status.status,
        detail = status.detail,
    )
end

function handle_integration_status(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/integrations/status")
        ctx, _store = _protected_context_and_store(services; request = request)
        authorize!(ctx, "configure", "integration")
        return _json_response(_integration_status_payload(services.config))
    catch err
        return _error_response(err)
    end
end

function handle_test_integration(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/integrations/test")
        ctx, _store = _protected_context_and_store(services; request = request)
        authorize!(ctx, "configure", "integration")
        return _json_response(_integration_test_payload(services.config, _requested_adapter_name(_json_body())))
    catch err
        return _error_response(err)
    end
end
