using UUIDs

const EVENT_ENVELOPE_TYPES = Set([
    "simulation.completed",
    "simulation.failed",
    "allocation.high_value_found",
    "recommendation.approved",
    "integration.adapter_failed",
    "backtest.policy_degraded",
    "workflow.allocation_approval_requested",
])

function _require_token(value, token_path::AbstractString)
    if value === nothing || (value isa AbstractString && isempty(strip(String(value))))
        throw(ApiError("VALIDATION_ERROR", "Missing required event token: $(token_path)"; status = 400))
    end
    return value
end

function _payload_at(payload::AbstractDict, path::AbstractString)
    current = payload
    for part in split(String(path), ".")
        if !(current isa AbstractDict) || !haskey(current, part)
            throw(ApiError("VALIDATION_ERROR", "Missing required event token: $(path)"; status = 400))
        end
        current = current[part]
    end
    return _require_token(current, path)
end

function validate_event_payload_tokens!(event_type::AbstractString, payload::AbstractDict)::AbstractDict
    required = String(event_type) == "allocation.high_value_found" ? [
        "tenant.display_name", "tenant.contact.email", "recommendation.id",
        "recommendation.net_value_cents", "recommendation.confidence_score",
        "recommendation.explanation_summary", "action_url",
    ] : startswith(String(event_type), "simulation.") ? [
        "tenant.display_name", "tenant.contact.email", "run.id", "run.name", "run.status", "action_url",
    ] : ["tenant.display_name", "tenant.contact.email", "action_url"]
    for token in required
        _payload_at(payload, token)
    end
    return payload
end

function build_event_envelope(event_type::AbstractString, tenant_id::UUID, event_id::AbstractString, payload::AbstractDict)::Dict{String,Any}
    event = String(event_type)
    event in EVENT_ENVELOPE_TYPES || notification_event_spec(event)
    _require_token(event_id, "event_id")
    validate_event_payload_tokens!(event, payload)
    return Dict{String,Any}(
        "event_type" => event,
        "event_id" => String(event_id),
        "tenant_id" => string(tenant_id),
        "payload" => payload,
    )
end
