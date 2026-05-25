using Genie.Router

function handle_list_notifications(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/notifications")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_notifications(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_mark_notification_read(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "PATCH", "/api/notifications/:id/read")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(mark_notification_read!(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end
