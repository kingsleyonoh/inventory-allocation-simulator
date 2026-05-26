using Dates
using UUIDs

function enqueue_workflow_execution!(store::MemoryTenantAdminStore, config::AppConfig, tenant_id::UUID, recommendation_id; event_id::AbstractString)::NamedTuple
    config.integrations.workflow_engine_enabled || return (queued = false, idempotent = false, outbox_id = nothing)
    isempty(strip(config.integrations.workflow_allocation_approval_workflow_id)) && throw(ApiError("VALIDATION_ERROR", "Workflow ID is required when Workflow Engine is enabled"; status = 400))
    payload = build_notification_payload(store, config, tenant_id, "allocation.high_value_found", recommendation_id)
    envelope = build_event_envelope("workflow.allocation_approval_requested", tenant_id, event_id, payload)
    existing = [row for row in values(store.ecosystem_outbox) if row[:tenant_id] == tenant_id && row[:event_id] == String(event_id) && row[:target] == "workflow_engine"]
    !isempty(existing) && return (queued = true, idempotent = true, outbox_id = string(first(existing)[:id]))
    now = Dates.now()
    id = uuid4()
    store.ecosystem_outbox[id] = Dict{Symbol,Any}(:id => id, :tenant_id => tenant_id, :event_type => "workflow.allocation_approval_requested", :event_id => String(event_id), :payload => envelope, :target => "workflow_engine", :status => "queued", :attempts => 0, :next_attempt_at => DateTime(1, 1, 1), :last_error => nothing, :created_at => now, :updated_at => now)
    return (queued = true, idempotent = false, outbox_id = string(id))
end

function dispatch_workflow_engine!(config::AppConfig, row; http_post::Function = integration_http_post)::NamedTuple
    base = _enabled_url!(config.integrations.workflow_engine_enabled, config.integrations.workflow_engine_url, "Workflow Engine")
    key = _enabled_key!(config.integrations.workflow_engine_enabled, config.integrations.workflow_engine_api_key, "Workflow Engine")
    workflow_id = _require_token(config.integrations.workflow_allocation_approval_workflow_id, "workflow_id")
    url = _join_url(base, "/api/workflows/$(workflow_id)/execute")
    body = Dict{String,Any}("trigger_data" => row[:payload]["payload"])
    response = http_post(url, body, Dict("X-API-Key" => key, "Content-Type" => "application/json"); timeout_seconds = 10)
    return (status = Int(response.status), body = String(response.body))
end
