struct ObservabilityService
    log_level::String
    metrics_token::String
    sentry_dsn::String
end

function build_observability_service(config::ObservabilityConfig)::ObservabilityService
    return ObservabilityService(config.metrics_token == "" ? "info" : get(ENV, "LOG_LEVEL", "info"), config.metrics_token, config.sentry_dsn)
end
