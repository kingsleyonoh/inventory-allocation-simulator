using Genie.Router

function handle_create_simulation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/simulations")
        ctx, store = _protected_context_and_store(services; request = request)
        idempotency_key = get(request.headers, "Idempotency-Key", nothing)
        return _json_response(create_simulation_run!(store, ctx, _json_body(); idempotency_key = idempotency_key); status = 202)
    catch err
        return _error_response(err)
    end
end

function handle_list_simulations(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/simulations")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_simulation_runs(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_get_simulation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/simulations/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_simulation_run(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end

function handle_cancel_simulation(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/simulations/:id/cancel")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(cancel_simulation_run!(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end
