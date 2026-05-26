using Dates
using UUIDs

function _tenant_payload(store::MemoryTenantAdminStore, tenant_id::UUID)::Dict{String,Any}
    tenant = get(store.tenants, tenant_id, nothing)
    tenant === nothing && throw(ApiError("NOT_FOUND", "Tenant not found"; status = 404))
    contact = Dict{String,Any}(String(k) => v for (k, v) in get(tenant, :contact, Dict{String,Any}()))
    payload = Dict{String,Any}(
        "display_name" => get(tenant, :display_name, nothing),
        "contact" => Dict{String,Any}("email" => get(contact, "email", nothing)),
    )
    _payload_at(Dict("tenant" => payload), "tenant.display_name")
    _payload_at(Dict("tenant" => payload), "tenant.contact.email")
    return payload
end

function _explanation_summary(explanation)::String
    binding = join(string.(get(explanation, "binding_constraints", String[])), ", ")
    tradeoffs = join(string.(get(explanation, "accepted_tradeoffs", String[])), ", ")
    isempty(binding) && (binding = "none")
    isempty(tradeoffs) && (tradeoffs = "none")
    return "binding: $(binding); tradeoffs: $(tradeoffs)"
end

function _run_payload(store::MemoryTenantAdminStore, run_id::UUID)::Dict{String,Any}
    run = get(store.simulation_runs, run_id, nothing)
    run === nothing && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
    return Dict{String,Any}("id" => string(run[:id]), "name" => String(run[:name]), "status" => String(run[:status]))
end

function _recommendation_payload(store::MemoryTenantAdminStore, recommendation_id::UUID)::Dict{String,Any}
    rec = get(store.allocation_recommendations, recommendation_id, nothing)
    rec === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    view = recommendation_view_model(rec)
    return Dict{String,Any}(
        "id" => string(rec[:id]),
        "net_value_cents" => view.net_value_cents,
        "confidence_score" => rec[:confidence_score],
        "explanation_summary" => _explanation_summary(rec[:explanation]),
    )
end

function build_notification_payload(store::MemoryTenantAdminStore, config::AppConfig, tenant_id::UUID, event_type::AbstractString, subject_id)::Dict{String,Any}
    subject_uuid = _uuid_value(subject_id)
    payload = Dict{String,Any}("tenant" => _tenant_payload(store, tenant_id))
    if startswith(String(event_type), "simulation.")
        run = get(store.simulation_runs, subject_uuid, nothing)
        (run === nothing || run[:tenant_id] != tenant_id) && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
        payload["run"] = _run_payload(store, subject_uuid)
        payload["action_url"] = _join_url(config.app.public_base_url, "/simulations/$(subject_uuid)")
    else
        rec = get(store.allocation_recommendations, subject_uuid, nothing)
        (rec === nothing || rec[:tenant_id] != tenant_id) && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
        payload["recommendation"] = _recommendation_payload(store, subject_uuid)
        payload["run"] = _run_payload(store, rec[:simulation_run_id])
        payload["action_url"] = _join_url(config.app.public_base_url, "/recommendations/$(subject_uuid)")
    end
    validate_event_payload_tokens!(event_type, payload)
    return payload
end

function enqueue_notification_hub_event!(store::MemoryTenantAdminStore, config::AppConfig, tenant_id::UUID, event_type::AbstractString, subject_id; event_id::AbstractString)::NamedTuple
    config.integrations.notification_hub_enabled || return (queued = false, idempotent = false, outbox_id = nothing)
    payload = build_notification_payload(store, config, tenant_id, event_type, subject_id)
    envelope = build_event_envelope(event_type, tenant_id, event_id, payload)
    existing = [row for row in values(store.ecosystem_outbox) if row[:tenant_id] == tenant_id && row[:event_id] == String(event_id) && row[:target] == "notification_hub"]
    !isempty(existing) && return (queued = true, idempotent = true, outbox_id = string(first(existing)[:id]))
    now = Dates.now()
    id = uuid4()
    store.ecosystem_outbox[id] = Dict{Symbol,Any}(:id => id, :tenant_id => tenant_id, :event_type => String(event_type), :event_id => String(event_id), :payload => envelope, :target => "notification_hub", :status => "queued", :attempts => 0, :next_attempt_at => DateTime(1, 1, 1), :last_error => nothing, :created_at => now, :updated_at => now)
    return (queued = true, idempotent = false, outbox_id = string(id))
end

function dispatch_notification_hub!(config::AppConfig, row; http_post::Function = integration_http_post)::NamedTuple
    url = _join_url(_enabled_url!(config.integrations.notification_hub_enabled, config.integrations.notification_hub_url, "Notification Hub"), "/api/events")
    key = _enabled_key!(config.integrations.notification_hub_enabled, config.integrations.notification_hub_api_key, "Notification Hub")
    response = http_post(url, row[:payload], Dict("Authorization" => "Bearer $(key)", "Content-Type" => "application/json"); timeout_seconds = 10)
    return (status = Int(response.status), body = String(response.body))
end
