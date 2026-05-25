function _recommendation_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        simulation_run_id = string(row[:simulation_run_id]),
        from_warehouse_id = string(row[:from_warehouse_id]),
        to_warehouse_id = string(row[:to_warehouse_id]),
        sku_id = string(row[:sku_id]),
        transfer_units = Float64(row[:transfer_units]),
        expected_stockout_reduction_units = Float64(row[:expected_stockout_reduction_units]),
        expected_margin_gain_cents = Int(row[:expected_margin_gain_cents]),
        transfer_cost_cents = Int(row[:transfer_cost_cents]),
        net_value_cents = Int(row[:net_value_cents]),
        confidence_score = Float64(row[:confidence_score]),
        explanation = row[:explanation],
        status = String(row[:status]),
    )
end

function persist_allocation_recommendation_create!(store::MemoryTenantAdminStore, row)
    store.allocation_recommendations[row[:id]] = row
    return row
end

function fetch_allocation_recommendations(store::MemoryTenantAdminStore, tenant_id::UUID, run_id::UUID)
    rows = [row for row in values(store.allocation_recommendations) if row[:tenant_id] == tenant_id && row[:simulation_run_id] == run_id]
    return sort(rows; by = row -> row[:created_at])
end

function persist_allocation_recommendation_create!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO allocation_recommendations (id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10, \$11, \$12, \$13::jsonb, \$14)
    """, [string(row[:id]), string(row[:tenant_id]), string(row[:simulation_run_id]), string(row[:from_warehouse_id]), string(row[:to_warehouse_id]), string(row[:sku_id]), row[:transfer_units], row[:expected_stockout_reduction_units], row[:expected_margin_gain_cents], row[:transfer_cost_cents], row[:net_value_cents], row[:confidence_score], JSON3.write(row[:explanation]), row[:status]])
    return row
end

function _sql_recommendation_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :simulation_run_id => UUID(String(row[3])),
        :from_warehouse_id => UUID(String(row[4])), :to_warehouse_id => UUID(String(row[5])), :sku_id => UUID(String(row[6])),
        :transfer_units => Float64(row[7]), :expected_stockout_reduction_units => Float64(row[8]),
        :expected_margin_gain_cents => Int(row[9]), :transfer_cost_cents => Int(row[10]), :net_value_cents => Int(row[11]),
        :confidence_score => Float64(row[12]), :explanation => JSON3.read(String(row[13])), :status => String(row[14]),
        :created_at => row[15], :updated_at => row[16],
    )
end

function fetch_allocation_recommendations(store::SqlTenantAdminStore, tenant_id::UUID, run_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status, created_at, updated_at
        FROM allocation_recommendations
        WHERE tenant_id = \$1 AND simulation_run_id = \$2
        ORDER BY created_at
    """, [string(tenant_id), string(run_id)])
    return [_sql_recommendation_row(row) for row in result]
end
