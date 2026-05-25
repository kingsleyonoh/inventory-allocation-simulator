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
    target_user_ids = isempty(recipients.user_ids) ? Union{Nothing,UUID}[nothing] : Union{Nothing,UUID}[UUID(id) for id in recipients.user_ids]
    created_ids = String[]
    for user_id in target_user_ids
        already_created = any(row -> row[:tenant_id] == event.tenant_id && row[:event_id] == event.event_id && row[:user_id] == user_id, values(store.local_notifications))
        already_created && continue
        row = _notification_row(event, user_id)
        row[:payload]["recipient_user_ids"] = recipients.user_ids
        row[:payload]["template_key"] = spec.template_key
        store.local_notifications[row[:id]] = row
        push!(created_ids, string(row[:id]))
    end
    existing = [row for row in values(store.local_notifications) if row[:tenant_id] == event.tenant_id && row[:event_id] == event.event_id]
    return (created_count = length(created_ids), idempotent = isempty(created_ids), notification_ids = sort([string(row[:id]) for row in existing]), recipient_user_ids = recipients.user_ids)
end

function create_local_notifications!(store::SqlTenantAdminStore, event)::NamedTuple
    spec = validate_notification_event!(event.event_type, event.template_key)
    recipients = resolve_notification_recipients(store, event.tenant_id, event.event_type; channel = :in_app, actor_user_id = event.actor_user_id)
    target_user_ids = isempty(recipients.user_ids) ? Union{Nothing,String}[nothing] : Union{Nothing,String}[id for id in recipients.user_ids]
    payload = Dict{String,Any}(event.payload)
    payload["recipient_user_ids"] = recipients.user_ids
    payload["template_key"] = spec.template_key
    notification_ids = String[]
    for user_id in target_user_ids
        result = LibPQ.execute(store.connection, """
            INSERT INTO local_notifications (id, tenant_id, user_id, event_type, event_id, title, body, severity, read_at, source_record_type, source_record_id, payload)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, NULL, \$9, \$10, \$11)
            ON CONFLICT (tenant_id, event_id, user_id) DO NOTHING
            RETURNING id
        """, [string(uuid4()), string(event.tenant_id), _sql_null(user_id), event.event_type, event.event_id, event.title, event.body, event.severity, event.source_record_type, string(event.source_record_id), JSON3.write(payload)])
        !isempty(result) && push!(notification_ids, String(first(result)[1]))
    end
    existing = LibPQ.execute(store.connection, """
        SELECT id FROM local_notifications
        WHERE tenant_id = \$1 AND event_id = \$2
        ORDER BY created_at
    """, [string(event.tenant_id), event.event_id])
    return (created_count = length(notification_ids), idempotent = isempty(notification_ids), notification_ids = [String(row[1]) for row in existing], recipient_user_ids = recipients.user_ids)
end

const NOTIFICATION_HUB_MIRROR_EVENTS = Set(["allocation.high_value_found", "simulation.failed", "backtest.policy_degraded"])
const NOTIFICATION_RESOURCE = "planning_data"
const NOTIFICATION_READ_ACTION = "read"

function _notification_response(row)::NamedTuple
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]),
        user_id = row[:user_id] === nothing ? nothing : string(row[:user_id]),
        event_type = String(row[:event_type]), event_id = String(row[:event_id]),
        title = String(row[:title]), body = String(row[:body]), severity = String(row[:severity]),
        read_at = row[:read_at] === nothing ? nothing : string(row[:read_at]),
        source_record_type = String(row[:source_record_type]), source_record_id = string(row[:source_record_id]),
        payload = row[:payload], created_at = string(row[:created_at]),
    )
end

function _notification_visible_to_user(row, ctx::TenantContext)::Bool
    row[:tenant_id] == ctx.tenant_id || return false
    row[:user_id] === nothing && return true
    ctx.user_id === nothing && return false
    return row[:user_id] == ctx.user_id
end

function list_notifications(store::MemoryTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, NOTIFICATION_READ_ACTION, NOTIFICATION_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["unread", "severity"]))
    rows = [row for row in values(store.local_notifications) if _notification_visible_to_user(row, ctx)]
    if get(page.filters, "unread", "false") == "true"
        rows = [row for row in rows if row[:read_at] === nothing]
    end
    if haskey(page.filters, "severity")
        severity = _validate_choice("severity", page.filters["severity"], Set(["info", "warning", "critical"]))
        rows = [row for row in rows if row[:severity] == severity]
    end
    rows = first(sort(rows; by = row -> row[:created_at], rev = true), min(page.limit, length(rows)))
    return _page_response(:notifications, [_notification_response(row) for row in rows], page)
end

function list_notifications(store::SqlTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, NOTIFICATION_READ_ACTION, NOTIFICATION_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["unread", "severity"]))
    unread_filter = get(page.filters, "unread", "false") == "true"
    severity_filter = haskey(page.filters, "severity") ? _validate_choice("severity", page.filters["severity"], Set(["info", "warning", "critical"])) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, user_id, event_type, event_id, title, body, severity, read_at, source_record_type, source_record_id, payload, created_at, updated_at
        FROM local_notifications
        WHERE tenant_id = \$1
          AND (user_id IS NULL OR user_id IS NOT DISTINCT FROM \$2::uuid)
          AND (\$3::boolean = false OR read_at IS NULL)
          AND severity = COALESCE(\$4::text, severity)
        ORDER BY created_at DESC
        LIMIT \$5
    """, [string(ctx.tenant_id), _sql_null(ctx.user_id === nothing ? nothing : string(ctx.user_id)), unread_filter, _sql_null(severity_filter), page.limit])
    return _page_response(:notifications, [_sql_notification_row(row) |> _notification_response for row in result], page)
end

function _sql_notification_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :user_id => _is_nullish(row[3]) ? nothing : UUID(String(row[3])),
        :event_type => String(row[4]), :event_id => String(row[5]), :title => String(row[6]), :body => String(row[7]), :severity => String(row[8]),
        :read_at => _is_nullish(row[9]) ? nothing : row[9], :source_record_type => String(row[10]), :source_record_id => UUID(String(row[11])),
        :payload => JSON3.read(String(row[12])), :created_at => row[13], :updated_at => row[14],
    )
end

function mark_notification_read!(store::MemoryTenantAdminStore, ctx::TenantContext, notification_id)::NamedTuple
    authorize!(ctx, NOTIFICATION_READ_ACTION, NOTIFICATION_RESOURCE)
    id = _uuid_value(notification_id)
    row = get(store.local_notifications, id, nothing)
    (row === nothing || !_notification_visible_to_user(row, ctx)) && throw(ApiError("NOT_FOUND", "Notification not found"; status = 404))
    if row[:read_at] !== nothing
        return (notification = _notification_response(row), idempotent = true)
    end
    updated = Dict{Symbol,Any}(row)
    updated[:read_at] = Dates.now()
    updated[:updated_at] = updated[:read_at]
    store.local_notifications[id] = updated
    return (notification = _notification_response(updated), idempotent = false)
end

function mark_notification_read!(store::SqlTenantAdminStore, ctx::TenantContext, notification_id)::NamedTuple
    authorize!(ctx, NOTIFICATION_READ_ACTION, NOTIFICATION_RESOURCE)
    id = _uuid_value(notification_id)
    existing = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, user_id, event_type, event_id, title, body, severity, read_at, source_record_type, source_record_id, payload, created_at, updated_at
        FROM local_notifications
        WHERE tenant_id = \$1 AND id = \$2 AND (user_id IS NULL OR user_id IS NOT DISTINCT FROM \$3::uuid)
        LIMIT 1
    """, [string(ctx.tenant_id), string(id), _sql_null(ctx.user_id === nothing ? nothing : string(ctx.user_id))])
    isempty(existing) && throw(ApiError("NOT_FOUND", "Notification not found"; status = 404))
    row = _sql_notification_row(first(existing))
    row[:read_at] !== nothing && return (notification = _notification_response(row), idempotent = true)
    updated = LibPQ.execute(store.connection, """
        UPDATE local_notifications SET read_at = now(), updated_at = now()
        WHERE tenant_id = \$1 AND id = \$2
        RETURNING id, tenant_id, user_id, event_type, event_id, title, body, severity, read_at, source_record_type, source_record_id, payload, created_at, updated_at
    """, [string(ctx.tenant_id), string(id)])
    return (notification = _notification_response(_sql_notification_row(first(updated))), idempotent = false)
end

function _outbox_payload(event)::Dict{String,Any}
    return Dict{String,Any}(
        "event_type" => event.event_type,
        "event_id" => event.event_id,
        "tenant_id" => string(event.tenant_id),
        "template_key" => event.template_key,
        "severity" => event.severity,
        "source_record_type" => event.source_record_type,
        "source_record_id" => string(event.source_record_id),
        "payload" => Dict{String,Any}(event.payload),
    )
end

function mirror_notification_hub_outbox!(store::MemoryTenantAdminStore, config::AppConfig, event)::NamedTuple
    config.integrations.notification_hub_enabled || return (mirrored = false, idempotent = false, outbox_id = nothing)
    event.event_type in NOTIFICATION_HUB_MIRROR_EVENTS || return (mirrored = false, idempotent = false, outbox_id = nothing)
    existing = [row for row in values(store.ecosystem_outbox) if row[:tenant_id] == event.tenant_id && row[:event_id] == event.event_id && row[:target] == "notification_hub"]
    !isempty(existing) && return (mirrored = true, idempotent = true, outbox_id = string(first(existing)[:id]))
    now = Dates.now()
    id = uuid4()
    store.ecosystem_outbox[id] = Dict{Symbol,Any}(:id => id, :tenant_id => event.tenant_id, :event_type => event.event_type, :event_id => event.event_id, :payload => _outbox_payload(event), :target => "notification_hub", :status => "queued", :attempts => 0, :next_attempt_at => now, :last_error => nothing, :created_at => now, :updated_at => now)
    return (mirrored = true, idempotent = false, outbox_id = string(id))
end

function mirror_notification_hub_outbox!(store::SqlTenantAdminStore, config::AppConfig, event)::NamedTuple
    config.integrations.notification_hub_enabled || return (mirrored = false, idempotent = false, outbox_id = nothing)
    event.event_type in NOTIFICATION_HUB_MIRROR_EVENTS || return (mirrored = false, idempotent = false, outbox_id = nothing)
    id = uuid4()
    result = LibPQ.execute(store.connection, """
        INSERT INTO ecosystem_outbox (id, tenant_id, event_type, event_id, payload, target, status, attempts)
        VALUES (\$1, \$2, \$3, \$4, \$5::jsonb, 'notification_hub', 'queued', 0)
        ON CONFLICT (event_id) DO NOTHING
        RETURNING id
    """, [string(id), string(event.tenant_id), event.event_type, event.event_id, JSON3.write(_outbox_payload(event))])
    if isempty(result)
        existing = LibPQ.execute(store.connection, "SELECT id FROM ecosystem_outbox WHERE tenant_id = \$1 AND event_id = \$2 AND target = 'notification_hub' LIMIT 1", [string(event.tenant_id), event.event_id])
        return (mirrored = true, idempotent = true, outbox_id = isempty(existing) ? nothing : String(first(existing)[1]))
    end
    return (mirrored = true, idempotent = false, outbox_id = String(first(result)[1]))
end
