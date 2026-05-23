using Test

const DATA_TEST_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const MIGRATION_DIR = joinpath(DATA_TEST_ROOT, "migrations")
const CORE_MIGRATION = joinpath(MIGRATION_DIR, "001_core_planning_spine.up.sql")
const CORE_MIGRATION_DOWN = joinpath(MIGRATION_DIR, "001_core_planning_spine.down.sql")

function normalized_core_sql(path::AbstractString = CORE_MIGRATION)
    return replace(lowercase(read(path, String)), r"\s+" => " ")
end

function table_block(sql::AbstractString, table::AbstractString)
    pattern = Regex("create table if not exists " * table * " \\((.*?)\\);", "is")
    match_result = match(pattern, sql)
    match_result === nothing && return ""
    return match_result.captures[1]
end

function assert_columns(sql::AbstractString, table::AbstractString, columns::Vector{String})
    block = table_block(sql, table)
    @test !isempty(block)
    for column in columns
        @test occursin(lowercase(column), block)
    end
end

@testset "Core planning migration defines PRD §4 tenant-scoped schema" begin
    @test isfile(CORE_MIGRATION)
    sql = normalized_core_sql()

    assert_columns(sql, "tenants", [
        "id uuid primary key",
        "name text not null",
        "legal_name text not null",
        "full_legal_name text not null",
        "display_name text not null",
        "address jsonb not null default '{}'",
        "registration jsonb not null default '{}'",
        "contact jsonb not null default '{}'",
        "wordmark text null",
        "api_key_hash text not null unique",
        "is_active boolean not null default true",
    ])
    @test occursin("create index if not exists tenants_api_key_hash_idx on tenants (api_key_hash)", sql)
    @test occursin("create index if not exists tenants_active_created_idx on tenants (is_active, created_at)", sql)

    assert_columns(sql, "users", [
        "tenant_id uuid not null references tenants(id)",
        "email text not null",
        "role text not null check (role in ('admin', 'planner', 'viewer'))",
        "is_active boolean not null default true",
    ])
    @test occursin("create unique index if not exists users_tenant_email_idx on users (tenant_id, email)", sql)
    @test occursin("create index if not exists users_tenant_role_idx on users (tenant_id, role)", sql)

    assert_columns(sql, "warehouses", [
        "tenant_id uuid not null references tenants(id)",
        "code text not null",
        "region text not null",
        "capacity_units numeric(14,2) not null",
        "handling_cost_cents integer not null default 0",
        "active boolean not null default true",
    ])
    @test occursin("create unique index if not exists warehouses_tenant_code_idx on warehouses (tenant_id, code)", sql)
    @test occursin("create index if not exists warehouses_tenant_region_idx on warehouses (tenant_id, region)", sql)
    @test occursin("create index if not exists warehouses_tenant_active_idx on warehouses (tenant_id, active)", sql)

    assert_columns(sql, "skus", [
        "tenant_id uuid not null references tenants(id)",
        "sku_code text not null",
        "category text not null",
        "unit_volume numeric(12,4) not null default 1",
        "unit_margin_cents integer not null default 0",
        "stockout_cost_cents integer not null default 0",
        "holding_cost_cents integer not null default 0",
        "active boolean not null default true",
    ])
    @test occursin("create unique index if not exists skus_tenant_sku_code_idx on skus (tenant_id, sku_code)", sql)
    @test occursin("create index if not exists skus_tenant_category_idx on skus (tenant_id, category)", sql)
    @test occursin("create index if not exists skus_tenant_active_idx on skus (tenant_id, active)", sql)

    assert_columns(sql, "inventory_positions", [
        "tenant_id uuid not null references tenants(id)",
        "warehouse_id uuid not null references warehouses(id)",
        "sku_id uuid not null references skus(id)",
        "on_hand_units numeric(14,2) not null default 0",
        "reserved_units numeric(14,2) not null default 0",
        "inbound_units numeric(14,2) not null default 0",
        "safety_stock_units numeric(14,2) not null default 0",
        "as_of timestamp not null",
        "source text not null check (source in ('manual', 'csv', 'api', 'simulation'))",
    ])
    @test occursin("create unique index if not exists inventory_positions_tenant_warehouse_sku_idx on inventory_positions (tenant_id, warehouse_id, sku_id)", sql)
    @test occursin("create index if not exists inventory_positions_tenant_sku_idx on inventory_positions (tenant_id, sku_id)", sql)
    @test occursin("create index if not exists inventory_positions_tenant_as_of_idx on inventory_positions (tenant_id, as_of)", sql)

    assert_columns(sql, "demand_history", [
        "tenant_id uuid not null references tenants(id)",
        "warehouse_id uuid not null references warehouses(id)",
        "sku_id uuid not null references skus(id)",
        "period_start date not null",
        "period_end date not null",
        "demand_units numeric(14,2) not null",
        "lost_sales_units numeric(14,2) not null default 0",
        "source text not null check (source in ('csv', 'api', 'manual'))",
    ])
    @test occursin("create unique index if not exists demand_history_tenant_sku_warehouse_period_idx on demand_history (tenant_id, sku_id, warehouse_id, period_start)", sql)
    @test occursin("create index if not exists demand_history_tenant_period_idx on demand_history (tenant_id, period_start, period_end)", sql)

    assert_columns(sql, "transfer_lanes", [
        "tenant_id uuid not null references tenants(id)",
        "from_warehouse_id uuid not null references warehouses(id)",
        "to_warehouse_id uuid not null references warehouses(id)",
        "lead_time_days integer not null check (lead_time_days >= 0)",
        "cost_per_unit_cents integer not null default 0",
        "capacity_units_day numeric(14,2) null",
        "active boolean not null default true",
    ])
    @test occursin("create unique index if not exists transfer_lanes_tenant_from_to_idx on transfer_lanes (tenant_id, from_warehouse_id, to_warehouse_id)", sql)
    @test occursin("create index if not exists transfer_lanes_tenant_active_idx on transfer_lanes (tenant_id, active)", sql)
end

@testset "Core planning migration tenant-scope guard covers every data-bearing table" begin
    @test isfile(CORE_MIGRATION)
    sql = normalized_core_sql()
    for table in ["users", "warehouses", "skus", "inventory_positions", "demand_history", "transfer_lanes"]
        block = table_block(sql, table)
        @test !isempty(block)
        @test occursin("tenant_id uuid not null", block)
    end
    @test !occursin("create table if not exists inventory_positions ( id uuid primary key, warehouse_id", sql)
end

@testset "Core planning down migration reverses created tables in dependency order" begin
    @test isfile(CORE_MIGRATION_DOWN)
    down_sql = normalized_core_sql(CORE_MIGRATION_DOWN)
    expected_order = ["transfer_lanes", "demand_history", "inventory_positions", "skus", "warehouses", "users", "tenants"]
    positions = [findfirst("drop table if exists $table", down_sql).start for table in expected_order]
    @test positions == sort(positions)
end
