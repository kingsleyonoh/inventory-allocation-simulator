using Genie.Router

function handle_list_recommendations(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/recommendations")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_recommendations(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_get_recommendation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/recommendations/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_recommendation(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end

function handle_approve_recommendation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/recommendations/:id/approve")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(approve_recommendation!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_reject_recommendation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/recommendations/:id/reject")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(reject_recommendation!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_expire_recommendation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/recommendations/:id/expire")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(expire_recommendation!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_export_recommendation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/recommendations/:id/export")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(export_recommendation!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end
