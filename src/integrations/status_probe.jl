using Dates
using UUIDs

const INTEGRATION_ADAPTER_FAILURE_SOURCE_ID = UUID("a3700000-0000-4000-8000-000000000001")

function _adapter_status(name::AbstractString, label::AbstractString, enabled::Bool; status::AbstractString = enabled ? "configured" : "disabled", detail::AbstractString = enabled ? "Configured" : "Adapter disabled")::NamedTuple
    return (name = String(name), label = String(label), enabled = enabled, status = String(status), detail = String(detail))
end

function _probe_http_adapter(name::AbstractString, label::AbstractString, enabled::Bool, url::AbstractString, key::AbstractString; http_get::Function, path::AbstractString = "/health")::NamedTuple
    !enabled && return _adapter_status(name, label, false)
    if isempty(strip(String(url))) || isempty(strip(String(key)))
        return _adapter_status(name, label, true; status = "failed", detail = "Adapter configuration incomplete")
    end
    try
        response = http_get(_join_url(url, path), Dict("X-API-Key" => key); timeout_seconds = 5)
        if 200 <= Int(response.status) < 300
            return _adapter_status(name, label, true; status = "healthy", detail = "Adapter reachable")
        end
        return _adapter_status(name, label, true; status = "failed", detail = "Adapter failed with HTTP $(response.status)")
    catch
        return _adapter_status(name, label, true; status = "failed", detail = "Adapter health check failed")
    end
end

function integration_adapter_statuses(config::AppConfig; now::DateTime = Dates.now(), http_get::Function = integration_http_get)::Vector{NamedTuple}
    return [
        _adapter_status("notification_hub", "Notification Hub", config.integrations.notification_hub_enabled; status = config.integrations.notification_hub_enabled ? "configured" : "disabled", detail = config.integrations.notification_hub_enabled ? "Events mirror to Notification Hub outbox" : "Adapter disabled"),
        _probe_http_adapter("workflow_engine", "Workflow Engine", config.integrations.workflow_engine_enabled, config.integrations.workflow_engine_url, config.integrations.workflow_engine_api_key; http_get = http_get),
        _probe_http_adapter("delivery_gateway", "Delivery Tracking Gateway", config.integrations.delivery_gateway_enabled, config.integrations.delivery_gateway_url, config.integrations.delivery_gateway_api_key; http_get = http_get, path = "/health"),
    ]
end

function _adapter_failure_event_id(statuses, now::DateTime)::String
    failed = join(sort([status.name for status in statuses if status.status == "failed"]), ",")
    return "integration-adapter-failed-$(Dates.format(Date(now), dateformat"yyyy-mm-dd"))-$(failed)"
end

function _integration_probe_tenant_ids(store::MemoryTenantAdminStore)::Vector{UUID}
    return [tenant[:id] for tenant in values(store.tenants) if Bool(get(tenant, :is_active, true))]
end

function _integration_probe_tenant_ids(store::SqlTenantAdminStore)::Vector{UUID}
    result = LibPQ.execute(store.connection, "SELECT id FROM tenants WHERE is_active = true ORDER BY created_at ASC")
    return [UUID(String(row[1])) for row in result]
end

function probe_integration_status!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    tenant_id::UUID;
    now::DateTime = Dates.now(),
    http_get::Function = integration_http_get,
)::NamedTuple
    statuses = integration_adapter_statuses(config; now = now, http_get = http_get)
    failed = [status for status in statuses if status.status == "failed"]
    isempty(failed) && return (statuses = statuses, failed_count = 0, notifications_created = 0)
    labels = [status.label for status in failed]
    payload = Dict{String,Any}(
        "failed_adapters" => [status.name for status in failed],
        "details" => [Dict("name" => status.name, "label" => status.label, "detail" => status.detail) for status in failed],
    )
    event = build_local_notification_event(
        "integration.adapter_failed",
        tenant_id,
        _adapter_failure_event_id(statuses, now);
        source_record_type = "integration_adapter",
        source_record_id = INTEGRATION_ADAPTER_FAILURE_SOURCE_ID,
        title = "Integration adapter failure",
        body = "$(join(labels, ", ")) adapter failure detected. Core recommendation status is unchanged; review adapter settings.",
        payload = payload,
    )
    created = create_local_notifications!(store, event)
    return (statuses = statuses, failed_count = length(failed), notifications_created = created.created_count)
end

function run_integration_status_probe!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    contexts::AbstractVector{TenantContext} = TenantContext[];
    now::DateTime = Dates.now(),
    http_get::Function = integration_http_get,
)::NamedTuple
    tenant_ids = isempty(contexts) ? _integration_probe_tenant_ids(store) : unique([ctx.tenant_id for ctx in contexts])
    results = [probe_integration_status!(store, config, tenant_id; now = now, http_get = http_get) for tenant_id in tenant_ids]
    return (
        tenants_checked = length(tenant_ids),
        failed_count = sum(result.failed_count for result in results),
        notifications_created = sum(result.notifications_created for result in results),
        results = results,
    )
end
