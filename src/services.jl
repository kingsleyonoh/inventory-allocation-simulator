struct AppServices
    config::AppConfig
    db::DBService
    cache::CacheService
    analytics::AnalyticsService
    jobs::JobService
    observability::ObservabilityService
    rate_limiter::MemoryRateLimiter
end

function build_services(config::AppConfig)::AppServices
    return AppServices(
        config,
        DBService(config.database.url),
        CacheService(config.database.redis_url),
        AnalyticsService(config.database.duckdb_path),
        build_job_service(),
        ObservabilityService(config.app.log_level, config.observability.metrics_token, config.observability.sentry_dsn),
        MemoryRateLimiter(),
    )
end

function shutdown!(services::AppServices; stop_http::Bool = true)::Nothing
    stop!(services.jobs)
    close!(services.db)
    if stop_http
        try
            Genie.down(; force = false)
        catch err
            @debug "Genie server shutdown skipped" exception = (err, catch_backtrace())
        end
    end
    return nothing
end

function install_shutdown_hook!(services::AppServices)::AppServices
    atexit(() -> shutdown!(services; stop_http = true))
    return services
end
