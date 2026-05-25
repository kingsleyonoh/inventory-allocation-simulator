using Test

const DATA_BATCH009_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const DATA_BATCH009_MIGRATION_DIR = joinpath(DATA_BATCH009_ROOT, "migrations")
const OPERATIONAL_MIGRATION = joinpath(DATA_BATCH009_MIGRATION_DIR, "002_operational_data_spine.up.sql")
const OPERATIONAL_MIGRATION_DOWN = joinpath(DATA_BATCH009_MIGRATION_DIR, "002_operational_data_spine.down.sql")

function normalized_operational_sql(path::AbstractString = OPERATIONAL_MIGRATION)
    return replace(lowercase(read(path, String)), r"\s+" => " ")
end

function operational_table_block(sql::AbstractString, table::AbstractString)
    pattern = Regex("create table if not exists " * table * " \\((.*?)\\);", "is")
    match_result = match(pattern, sql)
    match_result === nothing && return ""
    return match_result.captures[1]
end

function assert_operational_columns(sql::AbstractString, table::AbstractString, columns::Vector{String})
    block = operational_table_block(sql, table)
    @test !isempty(block)
    for column in columns
        @test occursin(lowercase(column), block)
    end
end

@testset "Operational data migration defines policy, run, and scenario storage" begin
    @test isfile(OPERATIONAL_MIGRATION)
    sql = normalized_operational_sql()

    assert_operational_columns(sql, "allocation_policies", [
        "tenant_id uuid not null references tenants(id)",
        "name text not null",
        "objective text not null check (objective in ('minimize_stockout_cost', 'maximize_margin', 'minimize_total_cost', 'balanced'))",
        "planning_horizon_days integer not null check (planning_horizon_days between 1 and 180)",
        "service_level_target numeric(5,4) not null check (service_level_target > 0 and service_level_target <= 1)",
        "max_transfer_cost_cents integer null",
        "allow_cross_region boolean not null default true",
        "frozen_until date null",
        "config jsonb not null default '{}'",
        "status text not null check (status in ('draft', 'active', 'archived'))",
    ])
    @test occursin("create index if not exists allocation_policies_tenant_status_idx on allocation_policies (tenant_id, status)", sql)
    @test occursin("create unique index if not exists allocation_policies_tenant_name_idx on allocation_policies (tenant_id, name)", sql)

    assert_operational_columns(sql, "simulation_runs", [
        "tenant_id uuid not null references tenants(id)",
        "policy_id uuid not null references allocation_policies(id)",
        "name text not null",
        "status text not null check (status in ('queued', 'running', 'completed', 'failed', 'cancelled'))",
        "input_snapshot jsonb not null",
        "scenario_count integer not null default 100 check (scenario_count between 1 and 100)",
        "started_at timestamp null",
        "completed_at timestamp null",
        "error_message text null",
        "created_by_user_id uuid null references users(id)",
    ])
    @test occursin("create index if not exists simulation_runs_tenant_status_created_idx on simulation_runs (tenant_id, status, created_at)", sql)
    @test occursin("create index if not exists simulation_runs_tenant_policy_created_idx on simulation_runs (tenant_id, policy_id, created_at)", sql)

    assert_operational_columns(sql, "demand_scenarios", [
        "tenant_id uuid not null references tenants(id)",
        "simulation_run_id uuid not null references simulation_runs(id)",
        "scenario_index integer not null",
        "probability_weight numeric(8,6) not null",
        "demand_payload jsonb not null",
    ])
    @test occursin("create unique index if not exists demand_scenarios_tenant_run_index_idx on demand_scenarios (tenant_id, simulation_run_id, scenario_index)", sql)
end

@testset "Operational data migration defines recommendation audit schema" begin
    @test isfile(OPERATIONAL_MIGRATION)
    sql = normalized_operational_sql()

    assert_operational_columns(sql, "allocation_recommendations", [
        "tenant_id uuid not null references tenants(id)",
        "simulation_run_id uuid not null references simulation_runs(id)",
        "from_warehouse_id uuid not null references warehouses(id)",
        "to_warehouse_id uuid not null references warehouses(id)",
        "sku_id uuid not null references skus(id)",
        "transfer_units numeric(14,2) not null check (transfer_units > 0)",
        "expected_stockout_reduction_units numeric(14,2) not null default 0",
        "expected_margin_gain_cents integer not null default 0",
        "transfer_cost_cents integer not null default 0",
        "net_value_cents integer not null default 0",
        "confidence_score numeric(5,4) not null check (confidence_score >= 0 and confidence_score <= 1)",
        "explanation jsonb not null",
        "status text not null check (status in ('proposed', 'approved', 'rejected', 'exported', 'expired'))",
    ])
    @test occursin("create index if not exists allocation_recommendations_tenant_run_status_idx on allocation_recommendations (tenant_id, simulation_run_id, status)", sql)
    @test occursin("create index if not exists allocation_recommendations_tenant_sku_status_idx on allocation_recommendations (tenant_id, sku_id, status)", sql)
    @test occursin("create index if not exists allocation_recommendations_tenant_lane_idx on allocation_recommendations (tenant_id, from_warehouse_id, to_warehouse_id)", sql)

    assert_operational_columns(sql, "recommendation_decisions", [
        "tenant_id uuid not null references tenants(id)",
        "recommendation_id uuid not null references allocation_recommendations(id)",
        "user_id uuid null references users(id)",
        "decision text not null check (decision in ('approved', 'rejected', 'exported', 'expired'))",
        "reason text null",
        "decided_at timestamp not null default now()",
    ])
    @test occursin("create index if not exists recommendation_decisions_tenant_recommendation_decided_idx on recommendation_decisions (tenant_id, recommendation_id, decided_at)", sql)
end

@testset "Operational data migration defines import and outbox retry storage" begin
    @test isfile(OPERATIONAL_MIGRATION)
    sql = normalized_operational_sql()

    assert_operational_columns(sql, "import_jobs", [
        "tenant_id uuid not null references tenants(id)",
        "import_type text not null check (import_type in ('warehouses', 'skus', 'inventory', 'demand', 'lanes'))",
        "status text not null check (status in ('uploaded', 'queued', 'running', 'completed', 'failed'))",
        "original_filename text not null",
        "file_path text not null",
        "row_count integer not null default 0",
        "error_report jsonb not null default '[]'",
    ])
    @test occursin("create index if not exists import_jobs_tenant_status_created_idx on import_jobs (tenant_id, status, created_at)", sql)
    @test occursin("create index if not exists import_jobs_tenant_type_created_idx on import_jobs (tenant_id, import_type, created_at)", sql)

    assert_operational_columns(sql, "ecosystem_outbox", [
        "tenant_id uuid not null references tenants(id)",
        "event_type text not null",
        "event_id text not null unique",
        "payload jsonb not null",
        "target text not null check (target in ('notification_hub', 'workflow_engine'))",
        "status text not null check (status in ('queued', 'sending', 'sent', 'failed', 'dead_letter'))",
        "attempts integer not null default 0",
        "next_attempt_at timestamp not null default now()",
        "last_error text null",
    ])
    @test occursin("create index if not exists ecosystem_outbox_tenant_status_next_attempt_idx on ecosystem_outbox (tenant_id, status, next_attempt_at)", sql)
    @test occursin("create index if not exists ecosystem_outbox_tenant_target_created_idx on ecosystem_outbox (tenant_id, target, created_at)", sql)
end

@testset "Operational data migration preserves tenant scope and reversible dependencies" begin
    @test isfile(OPERATIONAL_MIGRATION)
    @test isfile(OPERATIONAL_MIGRATION_DOWN)
    sql = normalized_operational_sql()

    for table in [
        "allocation_policies",
        "simulation_runs",
        "demand_scenarios",
        "allocation_recommendations",
        "recommendation_decisions",
        "import_jobs",
        "ecosystem_outbox",
    ]
        block = operational_table_block(sql, table)
        @test !isempty(block)
        @test occursin("tenant_id uuid not null", block)
    end

    down_sql = normalized_operational_sql(OPERATIONAL_MIGRATION_DOWN)
    expected_order = [
        "recommendation_decisions",
        "allocation_recommendations",
        "demand_scenarios",
        "simulation_runs",
        "ecosystem_outbox",
        "import_jobs",
        "allocation_policies",
    ]
    positions = [findfirst("drop table if exists $table", down_sql).start for table in expected_order]
    @test positions == sort(positions)
end
