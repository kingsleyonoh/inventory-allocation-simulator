function _validate_inventory_import_row(store::AbstractTenantAdminStore, tenant_id::UUID, rownum::Int, row::Dict{String,String})
    errors = NamedTuple[]
    warehouse = _find_warehouse_by_code(store, tenant_id, get(row, "warehouse_code", ""))
    sku = _find_sku_by_code(store, tenant_id, get(row, "sku_code", ""))
    warehouse === nothing && push!(errors, _row_error(rownum, "warehouse_code", "UNKNOWN_WAREHOUSE", "warehouse_code must match a tenant warehouse"))
    sku === nothing && push!(errors, _row_error(rownum, "sku_code", "UNKNOWN_SKU", "sku_code must match a tenant SKU"))
    on_hand = _parse_import_decimal(get(row, "on_hand_units", ""), "on_hand_units", rownum, errors)
    reserved = _parse_import_decimal(get(row, "reserved_units", "0"), "reserved_units", rownum, errors)
    inbound = _parse_import_decimal(get(row, "inbound_units", "0"), "inbound_units", rownum, errors)
    safety = _parse_import_decimal(get(row, "safety_stock_units", "0"), "safety_stock_units", rownum, errors)
    source = strip(get(row, "source", "csv"))
    if !(source in INVENTORY_SOURCES)
        push!(errors, _row_error(rownum, "source", "INVALID_SOURCE", "source must be manual, csv, api, or simulation"))
    end
    return errors, warehouse, sku, on_hand, reserved, inbound, safety, source
end

function _upsert_inventory_from_import!(store::MemoryTenantAdminStore, tenant_id::UUID, warehouse, sku, on_hand, reserved, inbound, safety, source)::Nothing
    existing_id = nothing
    for row in values(store.inventory_positions)
        if row[:tenant_id] == tenant_id && row[:warehouse_id] == warehouse[:id] && row[:sku_id] == sku[:id]
            existing_id = row[:id]
            break
        end
    end
    id = existing_id === nothing ? uuid4() : existing_id
    store.inventory_positions[id] = Dict{Symbol,Any}(
        :id => id,
        :tenant_id => tenant_id,
        :warehouse_id => warehouse[:id],
        :sku_id => sku[:id],
        :on_hand_units => on_hand,
        :reserved_units => reserved,
        :inbound_units => inbound,
        :safety_stock_units => safety,
        :as_of => now(),
        :source => source,
    )
    return nothing
end

function _upsert_inventory_from_import!(store::SqlTenantAdminStore, tenant_id::UUID, warehouse, sku, on_hand, reserved, inbound, safety, source)::Nothing
    LibPQ.execute(store.connection, """
        INSERT INTO inventory_positions (id, tenant_id, warehouse_id, sku_id, on_hand_units, reserved_units, inbound_units, safety_stock_units, as_of, source)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, now(), \$9)
        ON CONFLICT (tenant_id, warehouse_id, sku_id) DO UPDATE SET
            on_hand_units = EXCLUDED.on_hand_units,
            reserved_units = EXCLUDED.reserved_units,
            inbound_units = EXCLUDED.inbound_units,
            safety_stock_units = EXCLUDED.safety_stock_units,
            as_of = EXCLUDED.as_of,
            source = EXCLUDED.source,
            updated_at = now()
    """, [string(uuid4()), string(tenant_id), string(warehouse[:id]), string(sku[:id]), on_hand, reserved, inbound, safety, source])
    return nothing
end
