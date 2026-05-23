using Test

const LOCAL_NOTIFICATION_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const LOCAL_NOTIFICATION_MIGRATION_DIR = joinpath(LOCAL_NOTIFICATION_ROOT, "migrations")
const LOCAL_NOTIFICATION_MIGRATION = joinpath(LOCAL_NOTIFICATION_MIGRATION_DIR, "003_local_notifications.up.sql")
const LOCAL_NOTIFICATION_MIGRATION_DOWN = joinpath(LOCAL_NOTIFICATION_MIGRATION_DIR, "003_local_notifications.down.sql")

function normalized_notification_sql(path::AbstractString = LOCAL_NOTIFICATION_MIGRATION)
    return replace(lowercase(read(path, String)), r"\s+" => " ")
end

function notification_table_block(sql::AbstractString, table::AbstractString)
    pattern = Regex("create table if not exists " * table * " \\((.*?)\\);", "is")
    match_result = match(pattern, sql)
    match_result === nothing && return ""
    return match_result.captures[1]
end

function assert_notification_columns(sql::AbstractString, columns::Vector{String})
    block = notification_table_block(sql, "local_notifications")
    @test !isempty(block)
    for column in columns
        @test occursin(lowercase(column), block)
    end
end

@testset "Local notification migration defines tenant-scoped PRD §4.15 schema" begin
    @test isfile(LOCAL_NOTIFICATION_MIGRATION)
    sql = normalized_notification_sql()

    assert_notification_columns(sql, [
        "id uuid primary key",
        "tenant_id uuid not null references tenants(id)",
        "user_id uuid null references users(id)",
        "event_type text not null",
        "event_id text not null",
        "title text not null",
        "body text not null",
        "severity text not null check (severity in ('info', 'warning', 'critical'))",
        "read_at timestamp null",
        "source_record_type text not null check (source_record_type in ('simulation_run', 'allocation_recommendation', 'integration_adapter', 'backtest'))",
        "source_record_id uuid not null",
        "payload jsonb not null default '{}'",
    ])
end

@testset "Local notification migration enforces idempotency and unread list indexes" begin
    @test isfile(LOCAL_NOTIFICATION_MIGRATION)
    @test isfile(LOCAL_NOTIFICATION_MIGRATION_DOWN)
    sql = normalized_notification_sql()

    @test occursin("create unique index if not exists local_notifications_tenant_event_idx on local_notifications (tenant_id, event_id)", sql)
    @test occursin("create index if not exists local_notifications_tenant_user_read_created_idx on local_notifications (tenant_id, user_id, read_at, created_at)", sql)
    @test occursin("create index if not exists local_notifications_tenant_event_type_created_idx on local_notifications (tenant_id, event_type, created_at)", sql)
    @test occursin("create index if not exists local_notifications_tenant_source_record_idx on local_notifications (tenant_id, source_record_type, source_record_id)", sql)

    down_sql = normalized_notification_sql(LOCAL_NOTIFICATION_MIGRATION_DOWN)
    @test occursin("drop table if exists local_notifications", down_sql)
end
