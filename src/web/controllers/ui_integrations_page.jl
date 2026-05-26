function _adapter_health_badge(status::AbstractString)::String
    tone = status == "healthy" || status == "configured" ? "success" : status == "disabled" ? "muted" : "warning"
    label = status == "failed" ? "Adapter failed" : status == "disabled" ? "Adapter disabled" : status == "configured" ? "Configured" : "Healthy"
    return "<span class=\"ias-badge ias-badge-$tone\">$label</span>"
end

function _integration_status_cards(statuses)::String
    isempty(statuses) && return "<p class=\"ias-muted\">No adapters configured.</p>"
    return _join_html(["""
<article class=\"ias-panel\">
  <h2>$(_h(status.label))</h2>
  <p>$(_adapter_health_badge(status.status))</p>
  <p class=\"ias-muted\">$(_h(status.detail))</p>
</article>
""" for status in statuses])
end

function render_integration_settings_page(config::AppConfig, statuses = integration_adapter_statuses(config))::String
    body = """
<h1>Integration settings</h1>
<p class=\"ias-muted\">Optional ecosystem adapters are disabled by default. CSV/manual/local approval paths remain available when adapters are disabled or failing.</p>
<section class=\"ias-grid\" aria-label=\"Integration adapter health\">$(_integration_status_cards(statuses))</section>
<section class=\"ias-panel\"><h2>Configuration source</h2><p>Adapter URLs and API keys are loaded from environment configuration; secret values are never rendered in the operations console.</p><ul><li>Notification Hub enabled: $(_h(config.integrations.notification_hub_enabled))</li><li>Workflow Engine enabled: $(_h(config.integrations.workflow_engine_enabled))</li><li>Delivery Tracking Gateway enabled: $(_h(config.integrations.delivery_gateway_enabled))</li></ul></section>
"""
    return _app_shell("Integration settings", body; active = "Integrations")
end

function handle_integrations_page(services::AppServices)
    try
        ctx, _store = _protected_ui_context_and_store(services)
        authorize!(ctx, "configure", "integration")
        statuses = integration_adapter_statuses(services.config)
        return _html_response(render_integration_settings_page(services.config, statuses); status = 200)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fintegrations")
        return _ui_unavailable_response("Integration settings unavailable", err)
    end
end
