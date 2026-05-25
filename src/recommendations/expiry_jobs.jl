using Dates
using LibPQ
using UUIDs

function _policy_recommendation_expiry_days(policy_row; default_expiry_days::Integer = DEFAULT_RECOMMENDATION_EXPIRY_DAYS)::Int
    config = get(policy_row, :config, Dict{String,Any}())
    if config isa AbstractDict && haskey(config, "recommendation_expiry_days")
        value = Int(config["recommendation_expiry_days"])
        value > 0 || throw(ApiError("VALIDATION_ERROR", "Policy recommendation_expiry_days must be positive"; status = 400))
        return value
    end
    return Int(default_expiry_days)
end

function _recommendation_policy(store::MemoryTenantAdminStore, recommendation)
    run = get(store.simulation_runs, recommendation[:simulation_run_id], nothing)
    run === nothing && return nothing
    run[:tenant_id] == recommendation[:tenant_id] || return nothing
    policy = get(store.allocation_policies, run[:policy_id], nothing)
    policy === nothing && return nothing
    policy[:tenant_id] == recommendation[:tenant_id] || return nothing
    return policy
end

function expire_due_recommendations!(
    store::MemoryTenantAdminStore;
    now::DateTime = Dates.now(),
    default_expiry_days::Integer = DEFAULT_RECOMMENDATION_EXPIRY_DAYS,
)::NamedTuple
    checked = 0
    expired_ids = String[]
    for recommendation in sort(collect(values(store.allocation_recommendations)); by = row -> row[:created_at])
        recommendation[:status] == "proposed" || (checked += 1; continue)
        checked += 1
        policy = _recommendation_policy(store, recommendation)
        policy === nothing && continue
        expiry_days = _policy_recommendation_expiry_days(policy; default_expiry_days = default_expiry_days)
        if now >= _recommendation_created_at(recommendation) + Day(expiry_days)
            ctx = TenantContext(recommendation[:tenant_id]; role = "admin", auth_method = :job)
            result = expire_recommendation!(store, ctx, recommendation[:id], Dict("reason" => "hourly recommendation expiry"); now = () -> now, expiry_days = expiry_days)
            push!(expired_ids, result.recommendation.id)
        end
    end
    return (checked_count = checked, expired_count = length(expired_ids), expired_recommendation_ids = expired_ids)
end

function _sql_due_recommendations(store::SqlTenantAdminStore, now::DateTime, default_expiry_days::Integer)
    result = LibPQ.execute(store.connection, """
        WITH candidate_recommendations AS (
            SELECT
                r.id,
                r.tenant_id,
                r.created_at,
                CASE
                    WHEN p.config ? 'recommendation_expiry_days' THEN (p.config->>'recommendation_expiry_days')::int
                    ELSE \$2::int
                END AS expiry_days
            FROM allocation_recommendations r
            JOIN simulation_runs s ON s.tenant_id = r.tenant_id AND s.id = r.simulation_run_id
            JOIN allocation_policies p ON p.tenant_id = r.tenant_id AND p.id = s.policy_id
            WHERE r.status = 'proposed'
        )
        SELECT id, tenant_id, expiry_days
        FROM candidate_recommendations
        WHERE expiry_days > 0
          AND created_at + (expiry_days * interval '1 day') <= \$1::timestamp
        ORDER BY created_at
    """, [now, default_expiry_days])
    return [(recommendation_id = UUID(String(row[1])), tenant_id = UUID(String(row[2])), expiry_days = Int(row[3])) for row in result]
end

function expire_due_recommendations!(
    store::SqlTenantAdminStore;
    now::DateTime = Dates.now(),
    default_expiry_days::Integer = DEFAULT_RECOMMENDATION_EXPIRY_DAYS,
)::NamedTuple
    due = _sql_due_recommendations(store, now, default_expiry_days)
    expired_ids = String[]
    for item in due
        ctx = TenantContext(item.tenant_id; role = "admin", auth_method = :job)
        result = expire_recommendation!(store, ctx, item.recommendation_id, Dict("reason" => "hourly recommendation expiry"); now = () -> now, expiry_days = item.expiry_days)
        push!(expired_ids, result.recommendation.id)
    end
    return (checked_count = length(due), expired_count = length(expired_ids), expired_recommendation_ids = expired_ids)
end

recommendation_expiry_due(now::DateTime, last_run::Nothing)::Bool = true
recommendation_expiry_due(now::DateTime, last_run::DateTime)::Bool = now - last_run >= Hour(1)

function run_due_recommendation_expiry!(
    service::JobService,
    store::AbstractTenantAdminStore;
    now::DateTime = Dates.now(),
    default_expiry_days::Integer = DEFAULT_RECOMMENDATION_EXPIRY_DAYS,
)::NamedTuple
    recommendation_expiry_due(now, service.last_recommendation_expiry_at) || return (ran = false, checked_count = 0, expired_count = 0, expired_recommendation_ids = String[])
    result = expire_due_recommendations!(store; now = now, default_expiry_days = default_expiry_days)
    service.last_recommendation_expiry_at = now
    return merge((ran = true,), result)
end
