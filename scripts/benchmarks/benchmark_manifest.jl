function benchmark_manifest()::NamedTuple
    simulation = large_simulation_benchmark_fixture()
    recommendations = recommendation_list_benchmark_fixture()
    csv = csv_import_benchmark_fixture()
    large_simulation = benchmark_large_simulation()
    rec_benchmark = benchmark_recommendation_list_api()
    csv_benchmark = benchmark_csv_import()
    solver_timeout = benchmark_solver_timeout()
    outbox_dispatch = benchmark_outbox_dispatch_latency()
    return (
        schemaVersion = 1,
        source = "docs/inventory-allocation-simulator_prd.md §10b, §15",
        generated_at = string(Dates.now()),
        targets = performance_targets(),
        fixtures = _benchmark_fixture_manifest(simulation, recommendations, csv, solver_timeout, outbox_dispatch),
        benchmarks = (
            large_simulation = large_simulation,
            recommendation_list_api = rec_benchmark,
            csv_import = csv_benchmark,
            solver_timeout = solver_timeout,
            outbox_dispatch_latency = outbox_dispatch,
        ),
    )
end

function _benchmark_fixture_manifest(simulation, recommendations, csv, solver_timeout, outbox_dispatch)::NamedTuple
    return (
        simulation = (
            warehouses = simulation.warehouse_count,
            skus = simulation.sku_count,
            scenarios = simulation.scenario_count,
            target_p95_ms = performance_targets().simulation_p95_ms,
        ),
        recommendation_list_api = (
            recommendations = length(recommendations),
            target_p95_ms = performance_targets().recommendation_list_p95_ms,
            endpoint = "/api/recommendations",
        ),
        csv_import = (
            rows = csv_import_benchmark_row_count(csv),
            target_p95_ms = performance_targets().csv_import_p95_ms,
            endpoint = "/api/imports",
        ),
        dashboard_lcp = (
            pages = dashboard_lcp_benchmark_pages(),
            target_lcp_ms = performance_targets().dashboard_lcp_ms,
        ),
        solver_timeout = (
            configured_timeout_seconds = solver_timeout.configured_timeout_seconds,
            timeout_plus_grace_seconds = solver_timeout.timeout_plus_grace_seconds,
        ),
        outbox_dispatch_latency = (
            queued_events = outbox_dispatch.queued_events,
            target_p95_ms = performance_targets().outbox_dispatch_p95_ms,
        ),
    )
end
