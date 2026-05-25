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
