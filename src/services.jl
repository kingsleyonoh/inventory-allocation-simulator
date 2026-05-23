struct AppServices
    config::AppConfig
    db::DBService
    cache::CacheService
    analytics::AnalyticsService
    jobs::JobService
    observability::ObservabilityService
end

function build_services(config::AppConfig)::AppServices
    return AppServices(
        config,
        DBService(config.database.url),
        CacheService(config.database.redis_url),
        AnalyticsService(config.database.duckdb_path),
        build_job_service(),
        ObservabilityService(config.app.log_level, config.observability.metrics_token, config.observability.sentry_dsn),
    )
end
