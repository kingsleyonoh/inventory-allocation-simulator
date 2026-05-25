using Genie.Router
using Genie.Requests
using HTTP

function _query_params_dict()::Dict{String,String}
    parsed = Dict{String,String}()
    req = Requests.request()
    req === nothing && return parsed
    target = String(req.target)
    parts = split(target, "?"; limit = 2)
    length(parts) == 2 || return parsed
    for pair in split(parts[2], "&")
        isempty(pair) && continue
        bits = split(pair, "="; limit = 2)
        key = HTTP.URIs.unescapeuri(bits[1])
        value = length(bits) == 2 ? HTTP.URIs.unescapeuri(bits[2]) : ""
        parsed[key] = value
    end
    return parsed
end

function handle_rotate_api_key(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/settings/api-key/rotate")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(rotate_api_key!(store, services.config, ctx))
    catch err
        return _error_response(err)
    end
end

function handle_list_warehouses(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/warehouses")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_warehouses(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_create_warehouse(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/warehouses")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(create_warehouse!(store, ctx, _json_body()); status = 201)
    catch err
        return _error_response(err)
    end
end

function handle_get_warehouse(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/warehouses/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_warehouse(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end

function handle_update_warehouse(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "PATCH", "/api/warehouses/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(update_warehouse!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_delete_warehouse(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "DELETE", "/api/warehouses/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(deactivate_warehouse!(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end

function handle_list_skus(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/skus")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_skus(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_create_sku(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/skus")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(create_sku!(store, ctx, _json_body()); status = 201)
    catch err
        return _error_response(err)
    end
end

function handle_get_sku(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/skus/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_sku(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end

function handle_update_sku(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "PATCH", "/api/skus/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(update_sku!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_delete_sku(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "DELETE", "/api/skus/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(deactivate_sku!(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end

function handle_list_inventory(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/inventory")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_inventory_positions(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_update_inventory(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "PUT", "/api/inventory/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(update_inventory_position!(store, ctx, Router.params(:id), _json_body()))
    catch err
        return _error_response(err)
    end
end

function handle_list_demand_history(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/demand-history")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_demand_history(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_list_lanes(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/lanes")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_transfer_lanes(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_create_lane(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/lanes")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(create_transfer_lane!(store, ctx, _json_body()); status = 201)
    catch err
        return _error_response(err)
    end
end

function handle_list_policies(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/policies")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(list_allocation_policies(store, ctx; params = _query_params_dict()))
    catch err
        return _error_response(err)
    end
end

function handle_create_policy(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/policies")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(create_allocation_policy!(store, ctx, _json_body()); status = 201)
    catch err
        return _error_response(err)
    end
end

function _uploaded_import_file()
    for key in ("file", "csv", "upload")
        infilespayload(key) && return filespayload(key)
    end
    throw(ApiError("VALIDATION_ERROR", "multipart CSV file field is required"; status = 400))
end

function _multipart_import_payload()
    form = postpayload()
    query = _query_params_dict()
    uploaded = _uploaded_import_file()
    return (
        import_type = _payload_get(form, "import_type", get(query, "import_type", nothing)),
        original_filename = filename(uploaded),
        content = read(uploaded, String),
    )
end

function _json_import_payload()
    body = _json_body()
    return (
        import_type = _payload_get(body, "import_type", nothing),
        original_filename = _payload_get(body, "original_filename", "upload.csv"),
        content = String(_payload_get(body, "content", "")),
    )
end

function _import_request_payload()
    try
        return _multipart_import_payload()
    catch err
        if err isa ApiError && err.code == "VALIDATION_ERROR"
            return _json_import_payload()
        end
        rethrow(err)
    end
end

function handle_create_import(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "POST", "/api/imports")
        ctx, store = _protected_context_and_store(services; request = request)
        payload = _import_request_payload()
        job = create_import_job!(
            store,
            services.config,
            ctx,
            payload.import_type,
            payload.original_filename,
            payload.content,
        )
        return _json_response(job; status = 202)
    catch err
        return _error_response(err)
    end
end

function handle_get_import_result(services::AppServices)
    try
        request = _enforce_route_rate_limit!(services, "GET", "/api/imports/:id")
        ctx, store = _protected_context_and_store(services; request = request)
        return _json_response(get_import_result(store, ctx, Router.params(:id)))
    catch err
        return _error_response(err)
    end
end
