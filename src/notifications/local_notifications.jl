using Dates
using LibPQ
using JSON3
using UUIDs

struct NotificationEventSpec
    event_type::String
    channels::Vector{Symbol}
    recipient::String
    template_key::String
    urgency::String
    source_record_type::String
end

const NOTIFICATION_INVENTORY = Dict{String,NotificationEventSpec}(
    "simulation.completed" => NotificationEventSpec("simulation.completed", [:email, :in_app], "planners_admins", "simulation_completed", "Medium", "simulation_run"),
    "simulation.failed" => NotificationEventSpec("simulation.failed", [:email, :in_app], "actor_planner", "simulation_failed", "High", "simulation_run"),
    "allocation.high_value_found" => NotificationEventSpec("allocation.high_value_found", [:email, :in_app], "planners", "allocation_high_value_found", "High", "allocation_recommendation"),
    "recommendation.approved" => NotificationEventSpec("recommendation.approved", [:in_app], "admins_planners", "recommendation_approved", "Medium", "allocation_recommendation"),
    "integration.adapter_failed" => NotificationEventSpec("integration.adapter_failed", [:email], "admins", "integration_adapter_failed", "Medium", "integration_adapter"),
    "backtest.policy_degraded" => NotificationEventSpec("backtest.policy_degraded", [:email], "admins", "policy_degraded", "High", "backtest"),
)

function notification_event_spec(event_type::AbstractString)::NotificationEventSpec
    spec = get(NOTIFICATION_INVENTORY, String(event_type), nothing)
    spec === nothing && throw(ApiError("VALIDATION_ERROR", "Unknown notification event type"; status = 400))
    return spec
end

function validate_notification_event!(event_type::AbstractString, template_key::AbstractString)::NotificationEventSpec
    spec = notification_event_spec(event_type)
    String(template_key) == spec.template_key || throw(ApiError("VALIDATION_ERROR", "Notification template key does not match event inventory"; status = 400))
    return spec
end

function notification_severity(spec::NotificationEventSpec)::String
    spec.urgency == "High" && return "critical"
    spec.urgency == "Medium" && return "warning"
    return "info"
end

function _notification_opt_outs_value(value)::Dict{String,Any}
    _is_nullish(value) && return Dict{String,Any}()
    if value isa AbstractDict
        return Dict{String,Any}(String(k) => v for (k, v) in value)
    end
    parsed = JSON3.read(String(value))
    parsed isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(String(k) => v for (k, v) in parsed)
end

function _user_opted_out(row, spec::NotificationEventSpec, channel::Symbol)::Bool
    channel == :email || return false
    spec.urgency == "High" && return false
    prefs = _notification_opt_outs_value(get(row, :notification_opt_outs, Dict{String,Any}()))
    return get(prefs, "medium_email", false) == true || get(prefs, spec.template_key, false) == true || get(prefs, spec.event_type, false) == true
end

function _roles_for_spec(spec::NotificationEventSpec)::Set{String}
    spec.recipient in ("planners_admins", "admins_planners") && return Set(["admin", "planner"])
    spec.recipient == "planners" && return Set(["planner"])
    spec.recipient == "admins" && return Set(["admin"])
    spec.recipient == "actor_planner" && return Set(["planner"])
    return Set{String}()
end

function resolve_notification_recipients(
    store::MemoryTenantAdminStore,
    tenant_id::UUID,
    event_type::AbstractString;
    channel::Symbol = :in_app,
    actor_user_id::Union{Nothing,UUID} = nothing,
)::NamedTuple
    spec = notification_event_spec(event_type)
    channel in spec.channels || return (user_ids = String[], tenant_level = true, urgency = spec.urgency, template_key = spec.template_key)
    users = [row for row in values(store.users) if row[:tenant_id] == tenant_id && get(row, :is_active, true) == true]
    if spec.recipient == "actor_planner" && actor_user_id !== nothing
        users = [row for row in users if row[:id] == actor_user_id && row[:role] == "planner"]
    else
        roles = _roles_for_spec(spec)
        users = [row for row in users if String(row[:role]) in roles]
    end
    users = [row for row in users if !_user_opted_out(row, spec, channel)]
    user_ids = sort([string(row[:id]) for row in users])
    return (user_ids = user_ids, tenant_level = isempty(user_ids), urgency = spec.urgency, template_key = spec.template_key)
end

function resolve_notification_recipients(
    store::SqlTenantAdminStore,
    tenant_id::UUID,
    event_type::AbstractString;
    channel::Symbol = :in_app,
    actor_user_id::Union{Nothing,UUID} = nothing,
)::NamedTuple
    spec = notification_event_spec(event_type)
    channel in spec.channels || return (user_ids = String[], tenant_level = true, urgency = spec.urgency, template_key = spec.template_key)
    roles = collect(_roles_for_spec(spec))
    role_filter = isempty(roles) ? String[] : roles
    actor_filter = spec.recipient == "actor_planner" && actor_user_id !== nothing ? string(actor_user_id) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, role, notification_opt_outs
        FROM users
        WHERE tenant_id = \$1
          AND is_active = true
          AND role = ANY(\$2::text[])
          AND id = COALESCE(\$3::uuid, id)
        ORDER BY id
    """, [string(tenant_id), role_filter, _sql_null(actor_filter)])
    users = [Dict{Symbol,Any}(:id => UUID(String(row[1])), :role => String(row[2]), :notification_opt_outs => _notification_opt_outs_value(row[3])) for row in result]
    users = [row for row in users if !_user_opted_out(row, spec, channel)]
    user_ids = [string(row[:id]) for row in users]
    return (user_ids = user_ids, tenant_level = isempty(user_ids), urgency = spec.urgency, template_key = spec.template_key)
end

function build_local_notification_event(
    event_type::AbstractString,
    tenant_id::UUID,
    event_id::AbstractString;
    source_record_type::AbstractString,
    source_record_id,
    template_key::Union{Nothing,AbstractString} = nothing,
    title::Union{Nothing,AbstractString} = nothing,
    body::Union{Nothing,AbstractString} = nothing,
    payload::AbstractDict = Dict{String,Any}(),
    actor_user_id::Union{Nothing,UUID} = nothing,
)::NamedTuple
    spec = validate_notification_event!(event_type, template_key === nothing ? notification_event_spec(event_type).template_key : template_key)
    String(source_record_type) == spec.source_record_type || throw(ApiError("VALIDATION_ERROR", "Notification source record type does not match event inventory"; status = 400))
    return (
        event_type = spec.event_type,
        event_id = String(event_id),
        tenant_id = tenant_id,
        template_key = spec.template_key,
        title = title === nothing ? replace(spec.template_key, "_" => " ") : String(title),
        body = body === nothing ? "$(spec.event_type) requires attention" : String(body),
        severity = notification_severity(spec),
        source_record_type = spec.source_record_type,
        source_record_id = _uuid_value(source_record_id),
        payload = Dict{String,Any}(payload),
        actor_user_id = actor_user_id,
    )
end

function _notification_row(event, user_id)::Dict{Symbol,Any}
    now = Dates.now()
    payload = Dict{String,Any}(event.payload)
    payload["recipient_user_ids"] = get(payload, "recipient_user_ids", String[])
    return Dict{Symbol,Any}(
        :id => uuid4(), :tenant_id => event.tenant_id, :user_id => user_id,
        :event_type => event.event_type, :event_id => event.event_id,
        :title => event.title, :body => event.body, :severity => event.severity,
        :read_at => nothing, :source_record_type => event.source_record_type,
        :source_record_id => event.source_record_id, :payload => payload,
        :created_at => now, :updated_at => now,
    )
end

function create_local_notifications!(store::MemoryTenantAdminStore, event)::NamedTuple
    spec = validate_notification_event!(event.event_type, event.template_key)
    recipients = resolve_notification_recipients(store, event.tenant_id, event.event_type; channel = :in_app, actor_user_id = event.actor_user_id)
    existing = [row for row in values(store.local_notifications) if row[:tenant_id] == event.tenant_id && row[:event_id] == event.event_id]
    !isempty(existing) && return (created_count = 0, idempotent = true, notification_ids = sort([string(row[:id]) for row in existing]), recipient_user_ids = recipients.user_ids)
    user_id = isempty(recipients.user_ids) ? nothing : UUID(first(recipients.user_ids))
    row = _notification_row(event, user_id)
    row[:payload]["recipient_user_ids"] = recipients.user_ids
    row[:payload]["template_key"] = spec.template_key
    store.local_notifications[row[:id]] = row
    return (created_count = 1, idempotent = false, notification_ids = [string(row[:id])], recipient_user_ids = recipients.user_ids)
end

function create_local_notifications!(store::SqlTenantAdminStore, event)::NamedTuple
    spec = validate_notification_event!(event.event_type, event.template_key)
    recipients = resolve_notification_recipients(store, event.tenant_id, event.event_type; channel = :in_app, actor_user_id = event.actor_user_id)
    user_id = isempty(recipients.user_ids) ? nothing : first(recipients.user_ids)
    payload = Dict{String,Any}(event.payload)
    payload["recipient_user_ids"] = recipients.user_ids
    payload["template_key"] = spec.template_key
    result = LibPQ.execute(store.connection, """
        INSERT INTO local_notifications (id, tenant_id, user_id, event_type, event_id, title, body, severity, read_at, source_record_type, source_record_id, payload)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, NULL, \$9, \$10, \$11)
        ON CONFLICT (tenant_id, event_id) DO NOTHING
        RETURNING id
    """, [string(uuid4()), string(event.tenant_id), _sql_null(user_id), event.event_type, event.event_id, event.title, event.body, event.severity, event.source_record_type, string(event.source_record_id), JSON3.write(payload)])
    if isempty(result)
        existing = LibPQ.execute(store.connection, """
            SELECT id FROM local_notifications
            WHERE tenant_id = \$1 AND event_id = \$2
            ORDER BY created_at
        """, [string(event.tenant_id), event.event_id])
        return (created_count = 0, idempotent = true, notification_ids = [String(row[1]) for row in existing], recipient_user_ids = recipients.user_ids)
    end
    return (created_count = 1, idempotent = false, notification_ids = [String(first(result)[1])], recipient_user_ids = recipients.user_ids)
end
