using Test
using UUIDs
using InventoryAllocationSimulator

@testset "Tenant scoped query helpers require tenant context and filters" begin
    tenant_id = UUID("11111111-1111-1111-1111-111111111111")
    ctx = TenantContext(tenant_id; role = "planner", user_id = nothing, auth_method = :api_key)

    sql = tenant_scoped_select(ctx, "warehouses"; columns = ["id", "code"], alias = "w", filters = ["w.active = true"], order_by = "w.code ASC")
    @test occursin("FROM warehouses AS w", sql)
    @test occursin("WHERE w.tenant_id = \$1", sql)
    @test occursin("w.active = true", sql)
    @test occursin("ORDER BY w.code ASC", sql)

    @test_throws ArgumentError TenantContext(nothing; role = "planner")
    @test_throws ArgumentError tenant_scoped_select(ctx, "warehouses; drop table users")
    @test_throws ArgumentError assert_tenant_scoped_sql("SELECT * FROM warehouses")
end

@testset "Join-first inventory query scopes every joined planning table by tenant" begin
    tenant_id = UUID("22222222-2222-2222-2222-222222222222")
    ctx = TenantContext(tenant_id; role = "viewer", auth_method = :session)

    sql = inventory_positions_with_dimensions_sql(ctx; filters = ["s.category = \$2"], order_by = "ip.as_of DESC")
    @test occursin("FROM inventory_positions AS ip", sql)
    @test occursin("JOIN warehouses AS w ON w.id = ip.warehouse_id AND w.tenant_id = ip.tenant_id", sql)
    @test occursin("JOIN skus AS s ON s.id = ip.sku_id AND s.tenant_id = ip.tenant_id", sql)
    @test occursin("WHERE ip.tenant_id = \$1", sql)
    @test occursin("s.category = \$2", sql)
    @test !occursin("IN (SELECT", uppercase(sql))
end

@testset "Tenant filtering rejects cross-tenant rows before repositories return data" begin
    tenant_a = UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    tenant_b = UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    rows = [
        (tenant_id = tenant_a, code = "A-WH", name = "Tenant A warehouse"),
        (tenant_id = tenant_b, code = "B-WH", name = "Tenant B warehouse"),
    ]
    ctx = TenantContext(tenant_a; role = "planner")

    scoped = tenant_filter_records(ctx, rows)
    @test length(scoped) == 1
    @test scoped[1].code == "A-WH"
    @test all(row.tenant_id == tenant_a for row in scoped)
    @test !any(row.code == "B-WH" for row in scoped)
end
