function _maybe_http_recommendation_probe()::NamedTuple
    base_url = strip(get(ENV, "BENCHMARK_BASE_URL", ""))
    api_key = strip(get(ENV, "BENCHMARK_API_KEY", ""))
    if isempty(base_url) || isempty(api_key)
        return (enabled = false, status = nothing, elapsed_ms = nothing, note = "set BENCHMARK_BASE_URL and BENCHMARK_API_KEY to additionally time live HTTP.request /api/recommendations")
    end
    elapsed = _elapsed_ms() do
        response = HTTP.request("GET", string(rstrip(base_url, '/'), "/api/recommendations?limit=250&status=proposed"), ["X-API-Key" => api_key])
        response.status == 200 || throw(ErrorException("live recommendation API benchmark returned HTTP $(response.status)"))
    end
    return (enabled = true, status = 200, elapsed_ms = elapsed, note = "live HTTP.request /api/recommendations completed")
end

function benchmark_recommendation_list_api(; iterations::Integer = _benchmark_iterations("BENCHMARK_RECOMMENDATION_ITERATIONS", 3))::NamedTuple
    store = _benchmark_store(; include_dimensions = false)
    ctx = _benchmark_context(first(values(store.tenants))[:id])
    params = Dict("limit" => "250", "status" => "proposed")
    warmup = list_recommendations(store, ctx; params = params)
    samples = Float64[]
    last_count = length(warmup.recommendations)
    for _ in 1:Int(iterations)
        elapsed = _elapsed_ms() do
            page = list_recommendations(store, ctx; params = params)
            last_count = length(page.recommendations)
        end
        push!(samples, elapsed)
    end
    target = performance_targets().recommendation_list_p95_ms
    return (
        endpoint = "/api/recommendations",
        fixture_recommendations = length(store.allocation_recommendations),
        page_size = last_count,
        iterations = Int(iterations),
        samples_ms = samples,
        p95_ms = p95_ms(samples),
        target_p95_ms = target,
        passed_target = p95_ms(samples) <= target,
        measured_path = "list_recommendations production API service path with authz, pagination, filtering, and view-model serialization",
        live_http = _maybe_http_recommendation_probe(),
    )
end

function benchmark_csv_import(; iterations::Integer = _benchmark_iterations("BENCHMARK_CSV_IMPORT_ITERATIONS", 1))::NamedTuple
    csv = csv_import_benchmark_fixture()
    fixture_rows = csv_import_benchmark_row_count(csv)
    samples = Float64[]
    last_result = nothing
    for _ in 1:Int(iterations)
        upload_dir = mktempdir(; prefix = "ias-benchmark-import-")
        try
            store = _benchmark_store(; include_dimensions = true)
            ctx = _benchmark_context(first(values(store.tenants))[:id])
            config = _benchmark_config(upload_dir)
            elapsed = _elapsed_ms() do
                job = create_import_job!(store, config, ctx, "inventory", "benchmark-inventory.csv", csv)
                last_result = process_import_job!(store, config, ctx, job.id)
            end
            push!(samples, elapsed)
        finally
            isdir(upload_dir) && rm(upload_dir; recursive = true, force = true)
        end
    end
    target = performance_targets().csv_import_p95_ms
    return (
        endpoint = "/api/imports",
        fixture_rows = fixture_rows,
        iterations = Int(iterations),
        samples_ms = samples,
        p95_ms = p95_ms(samples),
        target_p95_ms = target,
        passed_target = p95_ms(samples) <= target,
        committed_rows = last_result === nothing ? 0 : last_result.committed_rows,
        final_status = last_result === nothing ? "not-run" : last_result.status,
        measured_path = "create_import_job! plus process_import_job! production import validation, artifact persistence, worker commit, and result reporting path",
    )
end
