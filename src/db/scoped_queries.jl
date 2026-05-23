const IDENTIFIER_PATTERN = r"^[A-Za-z_][A-Za-z0-9_]*$"

function _safe_identifier(identifier::AbstractString)::String
    text = String(identifier)
    occursin(IDENTIFIER_PATTERN, text) || throw(ArgumentError("unsafe SQL identifier: $identifier"))
    return text
end

function _safe_alias(alias::Union{Nothing,AbstractString})::Union{Nothing,String}
    alias === nothing && return nothing
    return _safe_identifier(alias)
end

function tenant_where_clause(alias::Union{Nothing,AbstractString} = nothing; parameter::Int = 1)::String
    prefix = alias === nothing || isempty(String(alias)) ? "" : string(_safe_identifier(String(alias)), ".")
    return string(prefix, "tenant_id = \$", parameter)
end

function assert_tenant_scoped_sql(sql::AbstractString)::String
    text = String(sql)
    occursin(r"(?i)tenant_id\s*=", text) || throw(ArgumentError("tenant-scoped SQL must filter by tenant_id"))
    return text
end

function tenant_scoped_select(
    ctx::TenantContext,
    table::AbstractString;
    columns::Vector{String} = ["*"],
    alias::Union{Nothing,AbstractString} = nothing,
    filters::Vector{String} = String[],
    order_by::Union{Nothing,AbstractString} = nothing,
)::String
    require_tenant_context(ctx)
    table_name = _safe_identifier(table)
    alias_name = _safe_alias(alias)
    from_clause = alias_name === nothing ? "FROM $table_name" : "FROM $table_name AS $alias_name"
    where_parts = vcat([tenant_where_clause(alias_name)], filters)
    sql = string("SELECT ", join(columns, ", "), " ", from_clause, " WHERE ", join(where_parts, " AND "))
    order_by === nothing || (sql = string(sql, " ORDER BY ", String(order_by)))
    return assert_tenant_scoped_sql(sql)
end

function inventory_positions_with_dimensions_sql(
    ctx::TenantContext;
    filters::Vector{String} = String[],
    order_by::Union{Nothing,AbstractString} = "ip.as_of DESC",
)::String
    require_tenant_context(ctx)
    columns = [
        "ip.id",
        "ip.tenant_id",
        "ip.on_hand_units",
        "ip.reserved_units",
        "ip.inbound_units",
        "ip.safety_stock_units",
        "ip.as_of",
        "w.code AS warehouse_code",
        "w.name AS warehouse_name",
        "s.sku_code",
        "s.name AS sku_name",
    ]
    joins = [
        "JOIN warehouses AS w ON w.id = ip.warehouse_id AND w.tenant_id = ip.tenant_id",
        "JOIN skus AS s ON s.id = ip.sku_id AND s.tenant_id = ip.tenant_id",
    ]
    where_parts = vcat(["ip.tenant_id = \$1"], filters)
    sql = string(
        "SELECT ", join(columns, ", "), " FROM inventory_positions AS ip ",
        join(joins, " "), " WHERE ", join(where_parts, " AND "),
    )
    order_by === nothing || (sql = string(sql, " ORDER BY ", String(order_by)))
    return assert_tenant_scoped_sql(sql)
end
