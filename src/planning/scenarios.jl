using Random

function _scenario_payload(forecasts::AbstractVector, rng::AbstractRNG, scenario_index::Int, seed::Integer)::Dict{String,Any}
    demands = Vector{Dict{String,Any}}()
    for forecast in forecasts
        noise = randn(rng) * max(forecast.uncertainty_units, 1.0)
        projected = max(0.0, forecast.baseline_units + noise)
        push!(demands, Dict{String,Any}(
            "warehouse_id" => forecast.warehouse_id,
            "sku_id" => forecast.sku_id,
            "demand_units" => round(projected; digits = 4),
            "baseline_units" => round(forecast.baseline_units; digits = 4),
            "uncertainty_units" => round(forecast.uncertainty_units; digits = 4),
            "stockout_periods" => forecast.stockout_periods,
        ))
    end
    return Dict{String,Any}(
        "seed" => seed,
        "scenario_index" => scenario_index,
        "demands" => demands,
    )
end

function _scenario_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        simulation_run_id = string(row[:simulation_run_id]),
        scenario_index = Int(row[:scenario_index]),
        probability_weight = Float64(row[:probability_weight]),
        demand_payload = row[:demand_payload],
    )
end

function persist_demand_scenario_create!(store::MemoryTenantAdminStore, row)
    if any(existing -> existing[:tenant_id] == row[:tenant_id] && existing[:simulation_run_id] == row[:simulation_run_id] && existing[:scenario_index] == row[:scenario_index], values(store.demand_scenarios))
        return first(existing for existing in values(store.demand_scenarios) if existing[:tenant_id] == row[:tenant_id] && existing[:simulation_run_id] == row[:simulation_run_id] && existing[:scenario_index] == row[:scenario_index])
    end
    store.demand_scenarios[row[:id]] = row
    return row
end

function fetch_demand_scenarios(store::MemoryTenantAdminStore, tenant_id::UUID, run_id::UUID)
    rows = [row for row in values(store.demand_scenarios) if row[:tenant_id] == tenant_id && row[:simulation_run_id] == run_id]
    return sort(rows; by = row -> row[:scenario_index])
end

function persist_demand_scenario_create!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO demand_scenarios (id, tenant_id, simulation_run_id, scenario_index, probability_weight, demand_payload)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6::jsonb)
        ON CONFLICT DO NOTHING
    """, [string(row[:id]), string(row[:tenant_id]), string(row[:simulation_run_id]), row[:scenario_index], row[:probability_weight], JSON3.write(row[:demand_payload])])
    return row
end

function _sql_scenario_row(row)::Dict{Symbol,Any}
    payload = _is_nullish(row[6]) ? Dict{String,Any}() : JSON3.read(String(row[6]))
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :simulation_run_id => UUID(String(row[3])),
        :scenario_index => Int(row[4]), :probability_weight => row[5], :demand_payload => payload,
    )
end

function fetch_demand_scenarios(store::SqlTenantAdminStore, tenant_id::UUID, run_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, scenario_index, probability_weight, demand_payload
        FROM demand_scenarios
        WHERE tenant_id = \$1 AND simulation_run_id = \$2
        ORDER BY scenario_index
    """, [string(tenant_id), string(run_id)])
    return [_sql_scenario_row(row) for row in result]
end

function generate_demand_scenarios!(
    store::AbstractTenantAdminStore,
    ctx::TenantContext,
    simulation_run_id;
    seed::Integer = 1,
)::Vector{NamedTuple}
    authorize!(ctx, "run_cancel", "simulation")
    run = fetch_simulation_run(store, ctx.tenant_id, _uuid_value(simulation_run_id))
    run === nothing && throw(ApiError("NOT_FOUND", "Simulation run not found"; status = 404))
    if !isempty(fetch_demand_scenarios(store, ctx.tenant_id, run[:id]))
        return [_scenario_response(row) for row in fetch_demand_scenarios(store, ctx.tenant_id, run[:id])]
    end
    preview = forecast_preview_from_snapshot(run[:input_snapshot]; scenario_count = run[:scenario_count])
    rng = MersenneTwister(seed)
    rows = Dict{Symbol,Any}[]
    count = Int(run[:scenario_count])
    for idx in 1:count
        row = Dict{Symbol,Any}(
            :id => uuid4(),
            :tenant_id => ctx.tenant_id,
            :simulation_run_id => run[:id],
            :scenario_index => idx,
            :probability_weight => 1.0 / count,
            :demand_payload => _scenario_payload(preview.forecasts, rng, idx, seed),
            :created_at => Dates.now(),
            :updated_at => Dates.now(),
        )
        persist_demand_scenario_create!(store, row)
        push!(rows, row)
    end
    return [_scenario_response(row) for row in rows]
end
