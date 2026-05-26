using Dates

const OUTBOX_MAX_ATTEMPTS = 5

function _outbox_backoff(attempts::Integer)::Second
    return Second(min(60, 2 ^ max(1, Int(attempts))))
end

function _due_outbox_rows(store::MemoryTenantAdminStore, now::DateTime; limit::Int = 100)::Vector{Dict{Symbol,Any}}
    rows = [row for row in values(store.ecosystem_outbox) if row[:status] in ("queued", "failed") && row[:next_attempt_at] <= now]
    return first(sort(rows; by = row -> row[:created_at]), min(limit, length(rows)))
end

function _sql_outbox_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => _tenant_admin_uuid_value(row[1]),
        :tenant_id => _tenant_admin_uuid_value(row[2]),
        :event_type => String(row[3]),
        :event_id => String(row[4]),
        :payload => JSON3.read(String(row[5])),
        :target => String(row[6]),
        :status => String(row[7]),
        :attempts => Int(row[8]),
        :next_attempt_at => row[9],
        :last_error => _nullable_text(row[10]),
        :created_at => row[11],
        :updated_at => row[12],
    )
end

function _due_outbox_rows(store::SqlTenantAdminStore, now::DateTime; limit::Int = 100)::Vector{Dict{Symbol,Any}}
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, event_type, event_id, payload, target, status, attempts, next_attempt_at, last_error, created_at, updated_at
        FROM ecosystem_outbox
        WHERE status IN ('queued', 'failed') AND next_attempt_at <= \$1
        ORDER BY created_at ASC
        LIMIT \$2
    """, [now, limit])
    return [_sql_outbox_row(row) for row in result]
end

function _persist_sql_outbox_row_state!(store::SqlTenantAdminStore, row)::Nothing
    LibPQ.execute(store.connection, """
        UPDATE ecosystem_outbox
        SET status = \$2,
            attempts = \$3,
            next_attempt_at = \$4,
            last_error = \$5,
            updated_at = \$6
        WHERE id = \$1
    """, [string(row[:id]), row[:status], row[:attempts], row[:next_attempt_at], _sql_null(row[:last_error]), row[:updated_at]])
    return nothing
end

function _send_outbox_row(config::AppConfig, row; http_post::Function)::NamedTuple
    if row[:target] == "notification_hub"
        return dispatch_notification_hub!(config, row; http_post = http_post)
    elseif row[:target] == "workflow_engine"
        return dispatch_workflow_engine!(config, row; http_post = http_post)
    end
    throw(ApiError("VALIDATION_ERROR", "Unknown outbox target"; status = 400))
end

function _record_outbox_success!(row, now::DateTime)::Nothing
    row[:status] = "sent"
    row[:last_error] = nothing
    row[:updated_at] = now
    return nothing
end

function _record_outbox_failure!(row, now::DateTime, status::Integer, body::AbstractString)::Symbol
    row[:attempts] = Int(row[:attempts]) + 1
    row[:last_error] = "HTTP $(status): $(body)"
    row[:updated_at] = now
    permanent = 400 <= status < 500
    exhausted = row[:attempts] >= OUTBOX_MAX_ATTEMPTS
    if permanent || exhausted
        row[:status] = "dead_letter"
        return :dead_letter
    end
    row[:status] = "failed"
    row[:next_attempt_at] = now + _outbox_backoff(row[:attempts])
    return :failed
end

function _record_outbox_exception!(row, now::DateTime, err)::Symbol
    row[:attempts] = Int(row[:attempts]) + 1
    row[:last_error] = sprint(showerror, err)
    row[:updated_at] = now
    if row[:attempts] >= OUTBOX_MAX_ATTEMPTS
        row[:status] = "dead_letter"
        return :dead_letter
    end
    row[:status] = "failed"
    row[:next_attempt_at] = now + _outbox_backoff(row[:attempts])
    return :failed
end

function _dispatch_outbox_rows!(store, config::AppConfig, rows; now::DateTime, http_post::Function, persist_state!::Function, request_id::Union{Nothing,AbstractString} = nothing)::NamedTuple
    sent = 0
    failed = 0
    dead_lettered = 0
    skipped_disabled = 0
    for row in rows
        row[:status] = "sending"
        row[:updated_at] = now
        persist_state!(row)
        try
            response = _send_outbox_row(config, row; http_post = http_post)
            if 200 <= response.status < 300
                _record_outbox_success!(row, now)
                sent += 1
            else
                outcome = _record_outbox_failure!(row, now, response.status, response.body)
                outcome == :dead_letter ? (dead_lettered += 1) : (failed += 1)
            end
        catch err
            if err isa ApiError && err.code == "ADAPTER_DISABLED"
                row[:status] = "queued"
                row[:updated_at] = now
                skipped_disabled += 1
            else
                outcome = _record_outbox_exception!(row, now, err)
                outcome == :dead_letter ? (dead_lettered += 1) : (failed += 1)
            end
        end
        persist_state!(row)
        _log_outbox_row_completed(row, request_id)
    end
    return (sent = sent, failed = failed, dead_lettered = dead_lettered, skipped_disabled = skipped_disabled)
end

function _log_outbox_row_completed(row, request_id::Union{Nothing,AbstractString})::Nothing
    @info structured_log_json(
        "info",
        "outbox dispatch row completed";
        request_id = request_id,
        log_module = "outbox",
        tenant_id = string(row[:tenant_id]),
        fields = Dict("target" => row[:target], "status" => row[:status], "attempts" => row[:attempts]),
    )
    return nothing
end

function dispatch_outbox_once!(store::MemoryTenantAdminStore, config::AppConfig; now::DateTime = Dates.now(), limit::Int = 100, http_post::Function = integration_http_post, request_id::Union{Nothing,AbstractString} = nothing)::NamedTuple
    rows = _due_outbox_rows(store, now; limit = limit)
    return _dispatch_outbox_rows!(store, config, rows; now = now, http_post = http_post, persist_state! = row -> nothing, request_id = request_id)
end

function dispatch_outbox_once!(store::SqlTenantAdminStore, config::AppConfig; now::DateTime = Dates.now(), limit::Int = 100, http_post::Function = integration_http_post, request_id::Union{Nothing,AbstractString} = nothing)::NamedTuple
    rows = _due_outbox_rows(store, now; limit = limit)
    return _dispatch_outbox_rows!(store, config, rows; now = now, http_post = http_post, persist_state! = row -> _persist_sql_outbox_row_state!(store, row), request_id = request_id)
end

function benchmark_outbox_dispatch_60s!(store::AbstractTenantAdminStore, config::AppConfig; now::DateTime = Dates.now(), http_post::Function = integration_http_post)::NamedTuple
    start = time()
    result = dispatch_outbox_once!(store, config; now = now, limit = 10_000, http_post = http_post)
    elapsed = time() - start
    return (sent = result.sent, failed = result.failed, dead_lettered = result.dead_lettered, elapsed_seconds = elapsed, within_60_seconds = elapsed <= 60.0)
end

function outbox_dispatcher!(store::AbstractTenantAdminStore, config::AppConfig; now::DateTime = Dates.now(), http_post::Function = integration_http_post, request_id::Union{Nothing,AbstractString} = nothing)::NamedTuple
    result = dispatch_outbox_once!(store, config; now = now, http_post = http_post, request_id = request_id)
    @info structured_log_json(
        "info",
        "outbox dispatcher completed";
        request_id = request_id,
        log_module = "outbox",
        fields = Dict("sent" => result.sent, "failed" => result.failed, "dead_lettered" => result.dead_lettered, "skipped_disabled" => result.skipped_disabled),
    )
    return result
end
