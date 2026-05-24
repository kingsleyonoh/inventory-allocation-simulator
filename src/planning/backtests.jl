using DuckDB
using UUIDs

const DAILY_BACKTEST_HOUR = 2
const BACKTEST_RESULT_NAMESPACE = UUID("02102121-0210-4210-8210-000000000021")

function _policy_field(policy, key::Symbol, default = nothing)
    policy isa NamedTuple && return haskey(policy, key) ? getfield(policy, key) : default
    return get(policy, key, get(policy, String(key), default))
end

function _demand_period_end(row)::Date
    value = row[:period_end]
    value isa Date && return value
    return Date(value)
end

function _backtest_id(tenant_id::UUID, policy_id, as_of::Date)::UUID
    return uuid5(BACKTEST_RESULT_NAMESPACE, string(tenant_id, ":", policy_id, ":", as_of))
end

function _recent_demand_rows(rows::AbstractVector, as_of::DateTime, lookback_days::Int)::Vector{Any}
    cutoff = Date(as_of) - Day(lookback_days)
    return Any[row for row in rows if _demand_period_end(row) >= cutoff && _demand_period_end(row) <= Date(as_of)]
end

function _backtest_report(ctx::TenantContext, policy, demand_rows::AbstractVector, as_of::DateTime, lookback_days::Int)::NamedTuple
    adjusted = sum(row -> Float64(row[:demand_units]) + Float64(row[:lost_sales_units]), demand_rows; init = 0.0)
    observed = sum(row -> Float64(row[:demand_units]), demand_rows; init = 0.0)
    target = Float64(_policy_field(policy, :service_level_target, 1.0))
    service_score = adjusted <= 0 ? 0.0 : observed / adjusted
    status = isempty(demand_rows) ? "insufficient_history" : (service_score + 1e-9 >= target ? "passing" : "degraded")
    policy_id = _policy_field(policy, :id)
    return (
        id = string(_backtest_id(ctx.tenant_id, policy_id, Date(as_of))),
        tenant_id = string(ctx.tenant_id),
        policy_id = string(policy_id),
        policy_name = String(_policy_field(policy, :name, "")),
        as_of = as_of,
        lookback_days = lookback_days,
        periods = length(demand_rows),
        adjusted_demand_units = round(adjusted; digits = 4),
        observed_demand_units = round(observed; digits = 4),
        service_score = round(service_score; digits = 6),
        service_level_target = round(target; digits = 6),
        quality_status = status,
    )
end

function run_daily_backtest!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext;
    as_of::DateTime = Dates.now(),
    lookback_days::Int = 180,
)::Vector{NamedTuple}
    authorize!(ctx, "read", "planning_data")
    lookback_days > 0 || throw(ApiError("VALIDATION_ERROR", "lookback_days must be greater than zero"; status = 400))
    policy_page = CursorPageRequest(SNAPSHOT_MAX_ROWS, nothing, Dict("status" => "active"))
    demand_page = CursorPageRequest(SNAPSHOT_MAX_ROWS, nothing, Dict{String,String}())
    policies = fetch_allocation_policies(store, ctx.tenant_id, policy_page)
    recent = _recent_demand_rows(fetch_demand_history(store, ctx.tenant_id, demand_page), as_of, lookback_days)
    return [_backtest_report(ctx, policy, recent, as_of, lookback_days) for policy in policies]
end

function daily_backtest_due(now::DateTime, last_run_date::Union{Nothing,Date})::Bool
    hour(now) >= DAILY_BACKTEST_HOUR || return false
    return last_run_date === nothing || Date(now) > last_run_date
end

function _ensure_backtest_table!(con)::Nothing
    DuckDB.execute(con, """
        CREATE TABLE IF NOT EXISTS policy_backtest_results (
            id VARCHAR PRIMARY KEY,
            tenant_id VARCHAR NOT NULL,
            policy_id VARCHAR NOT NULL,
            policy_name VARCHAR NOT NULL,
            as_of TIMESTAMP NOT NULL,
            lookback_days INTEGER NOT NULL,
            periods INTEGER NOT NULL,
            adjusted_demand_units DOUBLE NOT NULL,
            observed_demand_units DOUBLE NOT NULL,
            service_score DOUBLE NOT NULL,
            service_level_target DOUBLE NOT NULL,
            quality_status VARCHAR NOT NULL,
            created_at TIMESTAMP NOT NULL
        )
    """)
    return nothing
end

function persist_policy_backtest_results!(duckdb_path::AbstractString, reports::AbstractVector)::Int
    isempty(reports) && return 0
    dir = dirname(String(duckdb_path))
    !isempty(dir) && dir != "." && mkpath(dir)
    db = DuckDB.DB(String(duckdb_path))
    con = DuckDB.connect(db)
    try
        _ensure_backtest_table!(con)
        for report in reports
            DuckDB.execute(con, "DELETE FROM policy_backtest_results WHERE id = ?", [report.id])
            DuckDB.execute(con, """
                INSERT INTO policy_backtest_results (
                    id, tenant_id, policy_id, policy_name, as_of, lookback_days, periods,
                    adjusted_demand_units, observed_demand_units, service_score,
                    service_level_target, quality_status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                report.id,
                report.tenant_id,
                report.policy_id,
                report.policy_name,
                report.as_of,
                report.lookback_days,
                report.periods,
                report.adjusted_demand_units,
                report.observed_demand_units,
                report.service_score,
                report.service_level_target,
                report.quality_status,
                Dates.now(),
            ])
        end
    finally
        close(con)
        close(db)
    end
    return length(reports)
end

function run_daily_backtests!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    contexts::AbstractVector{TenantContext};
    as_of::DateTime = Dates.now(),
)::Vector{NamedTuple}
    reports = NamedTuple[]
    for ctx in contexts
        append!(reports, run_daily_backtest!(store, ctx; as_of = as_of, lookback_days = config.simulation.forecast_lookback_days))
    end
    persist_policy_backtest_results!(config.database.duckdb_path, reports)
    return reports
end

function _backtest_job_contexts(store::SqlTenantAdminStore)::Vector{TenantContext}
    result = LibPQ.execute(store.connection, """
        SELECT DISTINCT tenant_id
        FROM allocation_policies
        WHERE status = 'active'
        ORDER BY tenant_id
    """)
    return [TenantContext(UUID(String(row[1])); role = "admin", auth_method = :job) for row in result]
end

function run_daily_backtests!(
    store::SqlTenantAdminStore,
    config::AppConfig;
    as_of::DateTime = Dates.now(),
)::Vector{NamedTuple}
    return run_daily_backtests!(store, config, _backtest_job_contexts(store); as_of = as_of)
end
