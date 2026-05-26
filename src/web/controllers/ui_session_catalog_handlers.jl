function _html_response(html::AbstractString; status::Int = 200)
    return HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8"], String(html))
end

function _redirect_response(location::AbstractString; status::Int = 303)
    return HTTP.Response(status, ["Location" => String(location), "Cache-Control" => "no-store"], "")
end

function _form_payload()
    form = try
        Requests.postpayload()
    catch
        Dict{String,Any}()
    end
    isempty(form) || return form
    return _json_body()
end

function _login_payload()
    return _form_payload()
end

function _apply_warehouse_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload; warehouse_id = nothing)::NamedTuple
    return warehouse_id === nothing ? create_warehouse!(store, ctx, payload) : update_warehouse!(store, ctx, warehouse_id, payload)
end

function _apply_sku_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload; sku_id = nothing)::NamedTuple
    return sku_id === nothing ? create_sku!(store, ctx, payload) : update_sku!(store, ctx, sku_id, payload)
end

function _ui_action_failure_response(title::AbstractString, err)
    message = err isa AuthError || err isa ApiError ? err.message : "The request could not be completed"
    status = err isa AuthError || err isa ApiError ? err.status : 500
    return _html_response("<h1>$(_h(title))</h1><div class=\"ias-alert\" role=\"alert\">$(_h(message))</div>"; status = status)
end

function _ui_unavailable_response(title::AbstractString, err)
    message = err isa ApiError || err isa AuthzError ? err.message : "The page could not be loaded. Please retry or contact an administrator."
    status = err isa ApiError || err isa AuthzError ? err.status : 500
    return _html_response("<h1>$(_h(title))</h1><p>$(_h(message))</p>"; status = status)
end

function _find_active_user_by_email(store::MemoryTenantAdminStore, tenant_id::UUID, email::AbstractString)
    target = lowercase(strip(String(email)))
    for user in values(store.users)
        user[:tenant_id] == tenant_id || continue
        lowercase(String(user[:email])) == target && Bool(user[:is_active]) && return user
    end
    return nothing
end

function _find_active_user_by_email(store::SqlTenantAdminStore, tenant_id::UUID, email::AbstractString)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, email, name, role, is_active FROM users
        WHERE tenant_id = \$1 AND lower(email) = lower(\$2) AND is_active = true LIMIT 1
    """, [string(tenant_id), strip(String(email))])
    isempty(result) && return nothing
    row = first(result)
    return Dict{Symbol,Any}(:id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :email => row[3], :name => row[4], :role => row[5], :is_active => Bool(row[6]))
end

function _persist_ui_session!(::MemoryTenantAdminStore, session_id::String, tenant_id::UUID, user_id::UUID, expires_at::DateTime)
    return session_id
end

function _persist_ui_session!(store::SqlTenantAdminStore, session_id::String, tenant_id::UUID, user_id::UUID, expires_at::DateTime)
    LibPQ.execute(store.connection, """
        INSERT INTO user_sessions (id, tenant_id, user_id, expires_at)
        VALUES (\$1, \$2, \$3, \$4)
    """, [session_id, string(tenant_id), string(user_id), expires_at])
    return session_id
end

function authenticate_ui_login!(store::AbstractTenantAdminStore, config::AppConfig, payload; now::Function = Dates.now)::NamedTuple
    api_key = _required_text(payload, "api_key")
    email = _required_text(payload, "email")
    auth_record = lookup_tenant_by_api_key_hash(store, hash_api_key(api_key))
    auth_record === nothing && throw(AuthError("UNAUTHORIZED", "Invalid API key"; status = 401))
    auth_record.is_active || throw(AuthError("FORBIDDEN", "Tenant is inactive"; status = 403))
    user = _find_active_user_by_email(store, auth_record.tenant_id, email)
    user === nothing && throw(AuthError("UNAUTHORIZED", "User email is not active for this tenant"; status = 401))
    session_id = string(uuid4())
    expires_at = now() + Hour(UI_SESSION_TTL_HOURS)
    _persist_ui_session!(store, session_id, auth_record.tenant_id, user[:id], expires_at)
    return (cookie = signed_session_cookie(session_id, config.tenant.session_secret), expires_at = expires_at, user_id = string(user[:id]))
end

function _protected_ui_context_and_store(services::AppServices)
    request = _auth_request_from_http()
    return _protected_context_and_store(services; request = request)
end

function handle_login_page(services::AppServices)
    next = _safe_ui_next(get(_query_params_dict(), "next", "/dashboard"))
    return _html_response(render_login_page(next = next))
end

function handle_login(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/login")
        store = _store_for_services(services)
        payload = _login_payload()
        session = authenticate_ui_login!(store, services.config, payload)
        next = _safe_ui_next(_payload_get(payload, "next", "/dashboard"))
        cookie = string(UI_SESSION_COOKIE, "=", session.cookie, "; HttpOnly; SameSite=Lax; Path=/")
        return HTTP.Response(303, ["Location" => next, "Set-Cookie" => cookie, "Cache-Control" => "no-store"], "")
    catch err
        message = err isa AuthError || err isa ApiError ? err.message : "Unable to sign in"
        return _html_response(render_login_page(error = message); status = 401)
    end
end

function handle_logout(_services::AppServices)
    cookie = string(UI_SESSION_COOKIE, "=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0")
    return HTTP.Response(303, ["Location" => "/login", "Set-Cookie" => cookie, "Cache-Control" => "no-store"], "")
end

function handle_dashboard(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_dashboard_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fdashboard")
        return _ui_unavailable_response("Dashboard unavailable", err)
    end
end

function handle_imports_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_import_center_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fimports")
        return _ui_unavailable_response("Imports unavailable", err)
    end
end

function handle_warehouses_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_warehouses_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fwarehouses")
        return _ui_unavailable_response("Warehouses unavailable", err)
    end
end

function handle_create_warehouse_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/warehouses")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_warehouse_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/warehouses")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fwarehouses")
        return _ui_action_failure_response("Warehouse action failed", err)
    end
end

function handle_update_warehouse_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/warehouses/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_warehouse_ui_form!(store, ctx, _form_payload(); warehouse_id = Router.params(:id))
        return _redirect_response("/warehouses")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fwarehouses")
        return _ui_action_failure_response("Warehouse action failed", err)
    end
end

function handle_skus_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_skus_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fskus")
        return _ui_unavailable_response("SKUs unavailable", err)
    end
end

function handle_create_sku_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/skus")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_sku_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/skus")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fskus")
        return _ui_action_failure_response("SKU action failed", err)
    end
end

function handle_update_sku_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/skus/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_sku_ui_form!(store, ctx, _form_payload(); sku_id = Router.params(:id))
        return _redirect_response("/skus")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fskus")
        return _ui_action_failure_response("SKU action failed", err)
    end
end
