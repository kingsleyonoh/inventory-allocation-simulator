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

function create_local_notifications_with_optional_hub_mirror!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    event;
    mirror!::Function = mirror_notification_hub_outbox!,
)::NamedTuple
    local_result = create_local_notifications!(store, event)
    try
        hub = mirror!(store, config, event)
        return (local_delivery = local_result, hub = hub, hub_failed = false, hub_error = nothing)
    catch err
        return (local_delivery = local_result, hub = (mirrored = false, idempotent = false, outbox_id = nothing), hub_failed = true, hub_error = sprint(showerror, err))
    end
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
