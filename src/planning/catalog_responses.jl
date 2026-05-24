function _warehouse_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        code = String(row[:code]),
        name = String(row[:name]),
        region = String(row[:region]),
        latitude = _is_nullish(row[:latitude]) ? nothing : Float64(row[:latitude]),
        longitude = _is_nullish(row[:longitude]) ? nothing : Float64(row[:longitude]),
        capacity_units = Float64(row[:capacity_units]),
        handling_cost_cents = Int(row[:handling_cost_cents]),
        active = Bool(row[:active]),
    )
end

function _sku_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        sku_code = String(row[:sku_code]),
        name = String(row[:name]),
        category = String(row[:category]),
        unit_volume = Float64(row[:unit_volume]),
        unit_margin_cents = Int(row[:unit_margin_cents]),
        stockout_cost_cents = Int(row[:stockout_cost_cents]),
        holding_cost_cents = Int(row[:holding_cost_cents]),
        active = Bool(row[:active]),
    )
end

function _inventory_response(row)::NamedTuple
    available = Float64(row[:on_hand_units]) - Float64(row[:reserved_units])
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]), warehouse_id = string(row[:warehouse_id]),
        sku_id = string(row[:sku_id]), on_hand_units = Float64(row[:on_hand_units]),
        reserved_units = Float64(row[:reserved_units]), inbound_units = Float64(row[:inbound_units]),
        safety_stock_units = Float64(row[:safety_stock_units]), available_units = available,
        as_of = string(row[:as_of]), source = String(row[:source]),
    )
end

function _demand_response(row)::NamedTuple
    adjusted = Float64(row[:demand_units]) + Float64(row[:lost_sales_units])
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]), warehouse_id = string(row[:warehouse_id]),
        sku_id = string(row[:sku_id]), period_start = string(row[:period_start]), period_end = string(row[:period_end]),
        demand_units = Float64(row[:demand_units]), lost_sales_units = Float64(row[:lost_sales_units]),
        stockout_adjusted_demand_units = adjusted, source = String(row[:source]),
    )
end

function _lane_response(row)::NamedTuple
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]),
        from_warehouse_id = string(row[:from_warehouse_id]), to_warehouse_id = string(row[:to_warehouse_id]),
        lead_time_days = Int(row[:lead_time_days]), cost_per_unit_cents = Int(row[:cost_per_unit_cents]),
        capacity_units_day = _is_nullish(row[:capacity_units_day]) ? nothing : Float64(row[:capacity_units_day]),
        active = Bool(row[:active]),
    )
end

function _policy_response(row)::NamedTuple
    return (
        id = string(row[:id]), tenant_id = string(row[:tenant_id]), name = String(row[:name]),
        objective = String(row[:objective]), planning_horizon_days = Int(row[:planning_horizon_days]),
        service_level_target = Float64(row[:service_level_target]),
        max_transfer_cost_cents = _is_nullish(row[:max_transfer_cost_cents]) ? nothing : Int(row[:max_transfer_cost_cents]),
        allow_cross_region = Bool(row[:allow_cross_region]),
        frozen_until = _is_nullish(row[:frozen_until]) ? nothing : string(row[:frozen_until]),
        config = row[:config], status = String(row[:status]),
    )
end
