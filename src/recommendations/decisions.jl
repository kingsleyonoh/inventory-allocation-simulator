using Dates
using LibPQ
using UUIDs

const RECOMMENDATION_RESOURCE = "recommendation"
const RECOMMENDATION_DECIDE_EXPORT_ACTION = "decide_export"
const RECOMMENDATION_STATUSES = Set(["proposed", "approved", "rejected", "exported", "expired"])
const RECOMMENDATION_DECISIONS = Set(["approved", "rejected", "exported", "expired"])
const DEFAULT_RECOMMENDATION_EXPIRY_DAYS = 7

function _recommendation_decision_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        recommendation_id = string(row[:recommendation_id]),
        user_id = row[:user_id] === nothing ? nothing : string(row[:user_id]),
        decision = String(row[:decision]),
        reason = row[:reason] === nothing ? nothing : String(row[:reason]),
        decided_at = row[:decided_at],
    )
end

function _recommendation_transition_response(recommendation, decision; idempotent::Bool = false, export_eligible::Bool = false)::NamedTuple
    return (
        recommendation = _recommendation_response(recommendation),
        decision = _recommendation_decision_response(decision),
        idempotent = idempotent,
        export_eligible = export_eligible,
    )
end

function _fetch_recommendation_by_id(store::MemoryTenantAdminStore, tenant_id::UUID, recommendation_id::UUID)
    row = get(store.allocation_recommendations, recommendation_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function _fetch_recommendation_by_id(store::SqlTenantAdminStore, tenant_id::UUID, recommendation_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status, created_at, updated_at
        FROM allocation_recommendations
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(recommendation_id)])
    isempty(result) && return nothing
    return _sql_recommendation_row(first(result))
end

function _persist_recommendation_status!(store::MemoryTenantAdminStore, row, status::AbstractString)
    updated = Dict{Symbol,Any}(row)
    updated[:status] = String(status)
    updated[:updated_at] = Dates.now()
    store.allocation_recommendations[updated[:id]] = updated
    return updated
end

function _persist_recommendation_status!(store::SqlTenantAdminStore, row, status::AbstractString)
    LibPQ.execute(store.connection, """
        UPDATE allocation_recommendations
        SET status = \$3, updated_at = now()
        WHERE tenant_id = \$1 AND id = \$2
    """, [string(row[:tenant_id]), string(row[:id]), String(status)])
    updated = Dict{Symbol,Any}(row)
    updated[:status] = String(status)
    updated[:updated_at] = Dates.now()
    return updated
end

function _persist_recommendation_decision!(store::MemoryTenantAdminStore, row)
    store.recommendation_decisions[row[:id]] = row
    return row
end

function _persist_recommendation_decision!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO recommendation_decisions (id, tenant_id, recommendation_id, user_id, decision, reason, decided_at)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7)
    """, [string(row[:id]), string(row[:tenant_id]), string(row[:recommendation_id]), _sql_null(row[:user_id] === nothing ? nothing : string(row[:user_id])), row[:decision], _sql_null(row[:reason]), row[:decided_at]])
    return row
end

function _matching_existing_decision(store::MemoryTenantAdminStore, ctx::TenantContext, recommendation_id::UUID, decision::AbstractString, reason)
    matches = [row for row in values(store.recommendation_decisions) if row[:tenant_id] == ctx.tenant_id && row[:recommendation_id] == recommendation_id && row[:user_id] == ctx.user_id && row[:decision] == decision]
    isempty(matches) && return nothing
    sorted = sort(matches; by = row -> row[:decided_at])
    row = last(sorted)
    row[:reason] == reason && return row
    throw(ApiError("CONFLICT", "Duplicate recommendation decision body does not match existing audit row"; status = 409))
end

function _matching_existing_decision(store::SqlTenantAdminStore, ctx::TenantContext, recommendation_id::UUID, decision::AbstractString, reason)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, recommendation_id, user_id, decision, reason, decided_at
        FROM recommendation_decisions
        WHERE tenant_id = \$1
          AND recommendation_id = \$2
          AND user_id IS NOT DISTINCT FROM \$3::uuid
          AND decision = \$4
        ORDER BY decided_at DESC
        LIMIT 1
    """, [string(ctx.tenant_id), string(recommendation_id), _sql_null(ctx.user_id === nothing ? nothing : string(ctx.user_id)), String(decision)])
    isempty(result) && return nothing
    row = _sql_decision_row(first(result))
    row[:reason] == reason && return row
    throw(ApiError("CONFLICT", "Duplicate recommendation decision body does not match existing audit row"; status = 409))
end

function _sql_decision_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :recommendation_id => UUID(String(row[3])),
        :user_id => _is_nullish(row[4]) ? nothing : UUID(String(row[4])), :decision => String(row[5]),
        :reason => _is_nullish(row[6]) ? nothing : String(row[6]), :decided_at => row[7],
    )
end

function _decision_reason(payload; required::Bool = false)
    value = _payload_get(payload, "reason", nothing)
    value === nothing && (required ? throw(ApiError("VALIDATION_ERROR", "Recommendation decision reason is required"; status = 400)) : return nothing)
    reason = strip(String(value))
    if isempty(reason)
        required && throw(ApiError("VALIDATION_ERROR", "Recommendation decision reason is required"; status = 400))
        return nothing
    end
    return reason
end

function _recommendation_created_at(row)::DateTime
    value = get(row, :created_at, Dates.now())
    value isa DateTime && return value
    try
        return DateTime(String(value))
    catch
        return Dates.now()
    end
end

function _load_recommendation_for_decision(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id)::Dict{Symbol,Any}
    authorize!(ctx, RECOMMENDATION_DECIDE_EXPORT_ACTION, RECOMMENDATION_RESOURCE)
    row = _fetch_recommendation_by_id(store, ctx.tenant_id, _uuid_value(recommendation_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    return row
end

function _decision_audit_row(ctx::TenantContext, recommendation, decision::AbstractString, reason)::Dict{Symbol,Any}
    decided_at = Dates.now()
    return Dict{Symbol,Any}(
        :id => uuid4(), :tenant_id => ctx.tenant_id, :recommendation_id => recommendation[:id], :user_id => ctx.user_id,
        :decision => String(decision), :reason => reason, :decided_at => decided_at, :created_at => decided_at, :updated_at => decided_at,
    )
end

function _persist_recommendation_transition!(store::MemoryTenantAdminStore, recommendation, decision_row, next_status::AbstractString)
    updated = _persist_recommendation_status!(store, recommendation, next_status)
    _persist_recommendation_decision!(store, decision_row)
    return updated
end

function _persist_recommendation_transition!(store::SqlTenantAdminStore, recommendation, decision_row, next_status::AbstractString)
    LibPQ.execute(store.connection, "BEGIN")
    try
        updated = _persist_recommendation_status!(store, recommendation, next_status)
        _persist_recommendation_decision!(store, decision_row)
        LibPQ.execute(store.connection, "COMMIT")
        return updated
    catch err
        try
            LibPQ.execute(store.connection, "ROLLBACK")
        catch rollback_err
            @debug "Rollback failed after recommendation transition error" exception=(rollback_err, catch_backtrace())
        end
        rethrow(err)
    end
end

function _insert_transition!(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation, decision::AbstractString, next_status::AbstractString, reason; export_eligible::Bool = false)::NamedTuple
    existing = _matching_existing_decision(store, ctx, recommendation[:id], decision, reason)
    if existing !== nothing
        return _recommendation_transition_response(recommendation, existing; idempotent = true, export_eligible = export_eligible)
    end
    decision_row = _decision_audit_row(ctx, recommendation, decision, reason)
    updated = _persist_recommendation_transition!(store, recommendation, decision_row, next_status)
    return _recommendation_transition_response(updated, decision_row; export_eligible = export_eligible)
end

function approve_recommendation!(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id, payload = Dict{String,Any}())::NamedTuple
    recommendation = _load_recommendation_for_decision(store, ctx, recommendation_id)
    status = String(recommendation[:status])
    reason = _decision_reason(payload)
    if status == "approved"
        existing = _matching_existing_decision(store, ctx, recommendation[:id], "approved", reason)
        existing !== nothing && return _recommendation_transition_response(recommendation, existing; idempotent = true)
    end
    status == "proposed" || throw(ApiError("CONFLICT", "Only proposed recommendations can be approved"; status = 409))
    return _insert_transition!(store, ctx, recommendation, "approved", "approved", reason)
end

function reject_recommendation!(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id, payload = Dict{String,Any}(); require_reason::Bool = true)::NamedTuple
    recommendation = _load_recommendation_for_decision(store, ctx, recommendation_id)
    status = String(recommendation[:status])
    reason = _decision_reason(payload; required = require_reason)
    if status == "rejected"
        existing = _matching_existing_decision(store, ctx, recommendation[:id], "rejected", reason)
        existing !== nothing && return _recommendation_transition_response(recommendation, existing; idempotent = true)
    end
    status == "proposed" || throw(ApiError("CONFLICT", "Only proposed recommendations can be rejected"; status = 409))
    return _insert_transition!(store, ctx, recommendation, "rejected", "rejected", reason)
end

function expire_recommendation!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext,
    recommendation_id,
    payload = Dict{String,Any}();
    now::Function = Dates.now,
    expiry_days::Integer = DEFAULT_RECOMMENDATION_EXPIRY_DAYS,
)::NamedTuple
    recommendation = _load_recommendation_for_decision(store, ctx, recommendation_id)
    status = String(recommendation[:status])
    reason = _decision_reason(payload)
    if status == "expired"
        existing = _matching_existing_decision(store, ctx, recommendation[:id], "expired", reason)
        existing !== nothing && return _recommendation_transition_response(recommendation, existing; idempotent = true)
    end
    status == "proposed" || throw(ApiError("CONFLICT", "Only proposed recommendations can expire"; status = 409))
    age_deadline = _recommendation_created_at(recommendation) + Day(expiry_days)
    now() >= age_deadline || throw(ApiError("VALIDATION_ERROR", "Recommendation has not reached the policy expiry window"; status = 400))
    return _insert_transition!(store, ctx, recommendation, "expired", "expired", reason)
end

function export_recommendation!(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id, payload = Dict{String,Any}())::NamedTuple
    recommendation = _load_recommendation_for_decision(store, ctx, recommendation_id)
    status = String(recommendation[:status])
    reason = _decision_reason(payload)
    if status == "exported"
        existing = _matching_existing_decision(store, ctx, recommendation[:id], "exported", reason)
        existing !== nothing && return _recommendation_transition_response(recommendation, existing; idempotent = true, export_eligible = true)
    end
    status == "approved" || throw(ApiError("CONFLICT", "Only approved recommendations can be exported"; status = 409))
    return _insert_transition!(store, ctx, recommendation, "exported", "exported", reason; export_eligible = true)
end

function list_recommendations(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["simulation_run_id", "status"]))
    rows = fetch_recommendations(store, ctx.tenant_id, page)
    return _page_response(:recommendations, [_recommendation_response(row) for row in rows], page)
end

function get_recommendation(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = _fetch_recommendation_by_id(store, ctx.tenant_id, _uuid_value(recommendation_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    return _recommendation_response(row)
end

function fetch_recommendations(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.allocation_recommendations) if row[:tenant_id] == tenant_id]
    if haskey(page.filters, "simulation_run_id")
        run_id = _uuid_value(page.filters["simulation_run_id"])
        rows = [row for row in rows if row[:simulation_run_id] == run_id]
    end
    if haskey(page.filters, "status")
        status = _validate_choice("status", page.filters["status"], RECOMMENDATION_STATUSES)
        rows = [row for row in rows if row[:status] == status]
    end
    return first(sort(rows; by = row -> row[:created_at]), min(page.limit, length(rows)))
end

function fetch_recommendations(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    run_filter = haskey(page.filters, "simulation_run_id") ? string(_uuid_value(page.filters["simulation_run_id"])) : nothing
    status_filter = haskey(page.filters, "status") ? _validate_choice("status", page.filters["status"], RECOMMENDATION_STATUSES) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status, created_at, updated_at
        FROM allocation_recommendations
        WHERE tenant_id = \$1
          AND simulation_run_id = COALESCE(\$2::uuid, simulation_run_id)
          AND status = COALESCE(\$3::text, status)
        ORDER BY created_at
        LIMIT \$4
    """, [string(tenant_id), _sql_null(run_filter), _sql_null(status_filter), page.limit])
    return [_sql_recommendation_row(row) for row in result]
end
