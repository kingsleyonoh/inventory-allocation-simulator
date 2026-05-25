using Genie.Renderer: respond
using Genie.Requests
using Genie.Router
using JSON3

function _json_response(payload; status::Int = 200)
    return respond(JSON3.write(payload), :json, status)
end

function _error_response(err)
    status, body = endpoint_error_response(err)
    return respond(body, :json, status)
end

function _request_header(name::AbstractString)::Union{Nothing,String}
    req = Requests.request()
    req === nothing && return nothing
    target = lowercase(String(name))
    for (key, value) in req.headers
        lowercase(String(key)) == target && return String(value)
    end
    return nothing
end

function _session_cookie_from_header()::Union{Nothing,String}
    raw = _request_header("Cookie")
    raw === nothing && return nothing
    for part in split(raw, ";")
        pair = split(strip(part), "="; limit = 2)
        length(pair) == 2 && pair[1] == "ias_session" && return pair[2]
    end
    return nothing
end

function _json_body()
    payload = Requests.jsonpayload()
    payload !== nothing && return payload
    form = try
        Requests.postpayload()
    catch
        Dict{String,Any}()
    end
    isempty(form) || return form
    raw = strip(Requests.rawpayload())
    isempty(raw) && return Dict{String,Any}()
    parsed = try
        JSON3.read(raw)
    catch err
        throw(ApiError("VALIDATION_ERROR", "Request body must be valid JSON"; status = 400))
    end
    return parsed
end

function _auth_request_from_http()::AuthRequest
    return AuthRequest(_request_header("X-API-Key"), _session_cookie_from_header())
end

function _rate_limit_identity(request::AuthRequest)::String
    if request.api_key !== nothing && !isempty(strip(request.api_key))
        return string("api-key:", hash_api_key(request.api_key))
    elseif request.session_cookie !== nothing && !isempty(strip(request.session_cookie))
        return string("session:", hash_api_key(request.session_cookie))
    end
    forwarded_for = _request_header("X-Forwarded-For")
    forwarded_for !== nothing && !isempty(strip(forwarded_for)) && return string("anonymous:", strip(split(forwarded_for, ",")[1]))
    return "anonymous:unknown"
end

function _apply_rate_limit!(
    services::AppServices,
    method::AbstractString,
    path::AbstractString,
    identity::AbstractString,
)::RateLimitDecision
    policy = default_rate_limit_policy(method, path)
    decision = check_rate_limit!(services.rate_limiter, identity, policy)
    if !decision.allowed
        throw(ApiError(
            "RATE_LIMIT_EXCEEDED",
            "Rate limit exceeded";
            status = 429,
            details = [(retry_after_seconds = decision.retry_after_seconds, policy = policy.name,)],
        ))
    end
    return decision
end

function _enforce_route_rate_limit!(services::AppServices, method::AbstractString, path::AbstractString)::AuthRequest
    request = _auth_request_from_http()
    _apply_rate_limit!(services, method, path, _rate_limit_identity(request))
    return request
end

function _has_auth_material(request::AuthRequest)::Bool
    api_key_present = request.api_key !== nothing && !isempty(strip(request.api_key))
    cookie_present = request.session_cookie !== nothing && !isempty(strip(request.session_cookie))
    return api_key_present || cookie_present
end

function _store_for_services(services::AppServices)::SqlTenantAdminStore
    return SqlTenantAdminStore(connect!(services.db))
end

function _protected_context_and_store(services::AppServices; request::AuthRequest = _auth_request_from_http())
    if !_has_auth_material(request)
        throw(AuthError("UNAUTHORIZED", "Authentication required"; status = 401))
    end
    store = _store_for_services(services)
    ctx = resolve_tenant_context(
        store,
        request;
        cache = RequestCache(),
        session_secret = services.config.tenant.session_secret,
    )
    return ctx, store
end

function handle_register_tenant(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/api/tenants/register")
        if !services.config.tenant.self_registration_enabled
            throw(ApiError("FORBIDDEN", "Self-registration is disabled"; status = 403))
        end
        payload = _json_body()
        store = _store_for_services(services)
        return _json_response(register_tenant!(store, services.config, payload); status = 201)
    catch err
        return _error_response(err)
    end
end

function handle_tenant_me(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/tenants/me")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_tenant_profile(store, ctx))
    catch err
        return _error_response(err)
    end
end

function handle_get_tenant_settings(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/settings/tenant")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_tenant_profile(store, ctx))
    catch err
        return _error_response(err)
    end
end

function handle_update_tenant_settings(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "PATCH", "/api/settings/tenant")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(update_tenant_settings!(store, ctx, _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_list_users(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/users")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response((users = list_users(store, ctx),))
    catch err
        return _error_response(err)
    end
end

function handle_create_user(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/users")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(create_user!(store, ctx, _json_body()); status = 201)
    catch err
        return _error_response(err)
    end
end

function handle_update_user(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "PATCH", "/api/users/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(update_user!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end
