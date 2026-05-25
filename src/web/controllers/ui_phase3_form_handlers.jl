function handle_lanes_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_transfer_lanes_page(store, ctx))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Flanes")
        return _html_response("<h1>Transfer lanes unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_create_lane_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/lanes")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_lane_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/lanes")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Flanes")
        return _ui_action_failure_response("Transfer lane action failed", err)
    end
end

function handle_update_lane_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/lanes/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_lane_ui_form!(store, ctx, _form_payload(); lane_id = Router.params(:id))
        return _redirect_response("/lanes")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Flanes")
        return _ui_action_failure_response("Transfer lane action failed", err)
    end
end

function handle_policies_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_allocation_policies_page(store, ctx))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fpolicies")
        return _html_response("<h1>Policies unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_create_policy_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/policies")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_policy_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/policies")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fpolicies")
        return _ui_action_failure_response("Policy action failed", err)
    end
end

function handle_update_policy_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/policies/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_policy_ui_form!(store, ctx, _form_payload(); policy_id = Router.params(:id))
        return _redirect_response("/policies")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fpolicies")
        return _ui_action_failure_response("Policy action failed", err)
    end
end

function handle_settings_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_tenant_settings_page(store, services.config, ctx))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsettings")
        return _html_response("<h1>Settings unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_update_settings_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/settings")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_tenant_settings_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/settings")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsettings")
        return _ui_action_failure_response("Settings action failed", err)
    end
end

function handle_create_user_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/settings/users")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_user_create_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/settings")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsettings")
        return _ui_action_failure_response("User action failed", err)
    end
end

function handle_update_user_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/settings/users/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_user_update_ui_form!(store, ctx, Router.params(:id), _form_payload())
        return _redirect_response("/settings")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsettings")
        return _ui_action_failure_response("User action failed", err)
    end
end

function handle_rotate_api_key_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/settings/api-key/rotate")
        ctx, store = _protected_ui_context_and_store(services)
        rotate_api_key!(store, services.config, ctx)
        return _redirect_response("/settings")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsettings")
        return _ui_action_failure_response("API-key rotation failed", err)
    end
end

function handle_simulations_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_simulations_page(store, ctx))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsimulations")
        return _html_response("<h1>Simulations unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_create_simulation_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/simulations")
        ctx, store = _protected_ui_context_and_store(services)
        create_simulation_run!(store, ctx, _form_payload())
        return _redirect_response("/simulations")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsimulations")
        return _ui_action_failure_response("Simulation action failed", err)
    end
end

function handle_simulation_detail_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_simulation_detail_page(store, ctx, Router.params(:id)))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsimulations")
        return _html_response("<h1>Simulation detail unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = err isa ApiError ? err.status : 500)
    end
end

function handle_cancel_simulation_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/simulations/:id/cancel")
        ctx, store = _protected_ui_context_and_store(services)
        cancel_simulation_run!(store, ctx, Router.params(:id))
        return _redirect_response("/simulations")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsimulations")
        return _ui_action_failure_response("Simulation cancel failed", err)
    end
end

function _notification_rows(notifications)::String
    isempty(notifications) && return "<tr><td colspan=\"5\">No notifications yet.</td></tr>"
    return _join_html([begin
        read_state = n.read_at === nothing ? "Unread" : "Read"
        action = n.read_at === nothing ? "<form method=\"post\" action=\"/notifications/$(_h(n.id))/read\"><button class=\"ias-secondary\" type=\"submit\">Mark read</button></form>" : "<span class=\"ias-muted\">Already read</span>"
        "<tr><td>$(_h(n.title))<br><span class=\"ias-muted\">$(_h(n.body))</span></td><td>$(_h(n.severity))</td><td>$(_h(read_state))</td><td>$(_h(n.source_record_type))</td><td>$action</td></tr>"
    end for n in notifications])
end

function render_notifications_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    notifications = list_notifications(store, ctx; params = Dict("limit" => "100")).notifications
    unread = count(n -> n.read_at === nothing, notifications)
    body = """
<h1>Notifications</h1>
<p class=\"ias-muted\">Review tenant-scoped in-app alerts. Local notifications remain available when Notification Hub is disabled or failing.</p>
<section class=\"ias-panel\"><h2>Notification bell</h2><p><span class=\"ias-bell\" aria-label=\"$unread unread notifications\">Notification bell · $unread unread</span></p></section>
<section class=\"ias-table-wrap\"><table><caption>Notification list</caption><thead><tr><th>Message</th><th>Severity</th><th>State</th><th>Source</th><th>Action</th></tr></thead><tbody>$(_notification_rows(notifications))</tbody></table></section>
"""
    return _app_shell("Notifications", body; active = "Notifications")
end

function handle_notifications_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_notifications_page(store, ctx))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fnotifications")
        return _html_response("<h1>Notifications unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = err isa ApiError ? err.status : 500)
    end
end

function handle_mark_notification_read_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/notifications/:id/read")
        ctx, store = _protected_ui_context_and_store(services)
        mark_notification_read!(store, ctx, Router.params(:id))
        return _redirect_response("/notifications")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fnotifications")
        return _ui_action_failure_response("Notification action failed", err)
    end
end

function handle_recommendation_detail_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        return _html_response(render_recommendation_detail_page(store, ctx, Router.params(:id)))
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fsimulations")
        return _html_response("<h1>Recommendation unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = err isa ApiError ? err.status : 500)
    end
end
