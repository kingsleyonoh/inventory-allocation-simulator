using Dates
using UUIDs

const PERF_SIMULATION_P95_MS = 10 * 60 * 1000
const PERF_RECOMMENDATION_LIST_P95_MS = 250
const PERF_CSV_IMPORT_P95_MS = 3 * 60 * 1000
const PERF_DASHBOARD_LCP_MS = 2500
const PERF_SOLVER_TIMEOUT_GRACE_SECONDS = 10
const PERF_OUTBOX_DISPATCH_P95_MS = 60 * 1000

struct PerformanceBenchmarkFixture
    tenant_id::UUID
    warehouse_count::Int
    sku_count::Int
    scenario_count::Int
    warehouses::Vector{NamedTuple}
    skus::Vector{NamedTuple}
    demand_scenarios::Vector{NamedTuple}
end

function performance_targets()::NamedTuple
    return (
        simulation_p95_ms = PERF_SIMULATION_P95_MS,
        recommendation_list_p95_ms = PERF_RECOMMENDATION_LIST_P95_MS,
        csv_import_p95_ms = PERF_CSV_IMPORT_P95_MS,
        dashboard_lcp_ms = PERF_DASHBOARD_LCP_MS,
        solver_timeout_grace_seconds = PERF_SOLVER_TIMEOUT_GRACE_SECONDS,
        outbox_dispatch_p95_ms = PERF_OUTBOX_DISPATCH_P95_MS,
    )
end

_positive_benchmark_dimension(name::AbstractString, value::Integer)::Int = value > 0 ? Int(value) : throw(ArgumentError("$name must be positive"))

function _benchmark_uuid(prefix::Integer, index::Integer)::UUID
    return UUID("$(lpad(prefix, 8, '0'))-0040-4000-8000-$(lpad(index, 12, '0'))")
end

function _benchmark_warehouses(tenant_id::UUID, count::Int)::Vector{NamedTuple}
    return [(
        id = _benchmark_uuid(40, idx),
        tenant_id = tenant_id,
        code = "WH$(lpad(idx, 3, '0'))",
        name = "Benchmark warehouse $(idx)",
        region = "R$(1 + mod(idx - 1, 10))",
        capacity_units = 200_000.0,
        handling_cost_cents = 10 + mod(idx, 7),
        active = true,
    ) for idx in 1:count]
end

function _benchmark_skus(tenant_id::UUID, count::Int)::Vector{NamedTuple}
    return [(
        id = _benchmark_uuid(41, idx),
        tenant_id = tenant_id,
        sku_code = "SKU$(lpad(idx, 5, '0'))",
        name = "Benchmark SKU $(idx)",
        category = "C$(1 + mod(idx - 1, 20))",
        unit_volume = 1.0 + mod(idx, 5) / 10,
        unit_margin_cents = 100 + mod(idx, 50),
        stockout_cost_cents = 250 + mod(idx, 100),
        holding_cost_cents = 5 + mod(idx, 9),
        active = true,
    ) for idx in 1:count]
end

function _benchmark_scenarios(tenant_id::UUID, count::Int)::Vector{NamedTuple}
    return [(
        id = _benchmark_uuid(42, idx),
        tenant_id = tenant_id,
        scenario_index = idx,
        probability_weight = 1.0 / count,
        seed = 40_000 + idx,
    ) for idx in 1:count]
end

function large_simulation_benchmark_fixture(; warehouse_count::Integer = 50, sku_count::Integer = 2_000, scenario_count::Integer = 100)::PerformanceBenchmarkFixture
    warehouses_n = _positive_benchmark_dimension("warehouse_count", warehouse_count)
    skus_n = _positive_benchmark_dimension("sku_count", sku_count)
    scenarios_n = _positive_benchmark_dimension("scenario_count", scenario_count)
    tenant_id = UUID("40404040-0040-4040-8040-404040404040")
    return PerformanceBenchmarkFixture(
        tenant_id,
        warehouses_n,
        skus_n,
        scenarios_n,
        _benchmark_warehouses(tenant_id, warehouses_n),
        _benchmark_skus(tenant_id, skus_n),
        _benchmark_scenarios(tenant_id, scenarios_n),
    )
end

function recommendation_list_benchmark_fixture(; count::Integer = 10_000, tenant_id::UUID = UUID("40404040-0040-4040-8040-404040404040"))::Vector{Dict{Symbol,Any}}
    total = _positive_benchmark_dimension("count", count)
    run_id = UUID("43000000-0040-4000-8000-000000000001")
    from_wh = UUID("40000000-0040-4000-8000-000000000001")
    to_wh = UUID("40000000-0040-4000-8000-000000000002")
    return [Dict{Symbol,Any}(
        :id => _benchmark_uuid(44, idx),
        :tenant_id => tenant_id,
        :simulation_run_id => run_id,
        :from_warehouse_id => from_wh,
        :to_warehouse_id => to_wh,
        :sku_id => _benchmark_uuid(41, 1 + mod(idx - 1, 2_000)),
        :transfer_units => 10.0 + mod(idx, 25),
        :expected_stockout_reduction_units => 15.0 + mod(idx, 50),
        :expected_margin_gain_cents => 5_000 + idx,
        :transfer_cost_cents => 1_000 + mod(idx, 250),
        :net_value_cents => 4_000 + idx - mod(idx, 250),
        :confidence_score => 0.80,
        :explanation => Dict("binding_constraints" => ["stock", "lane_capacity"], "scenario_sensitivity" => "benchmark"),
        :status => "proposed",
        :created_at => DateTime(2026, 5, 26),
        :updated_at => DateTime(2026, 5, 26),
    ) for idx in 1:total]
end

function csv_import_benchmark_fixture(; row_count::Integer = 100_000)::String
    total = _positive_benchmark_dimension("row_count", row_count)
    buffer = IOBuffer()
    println(buffer, "warehouse_code,sku_code,on_hand_units,reserved_units,inbound_units,safety_stock_units,as_of")
    for idx in 1:total
        wh = "WH$(lpad(1 + mod(idx - 1, 50), 3, '0'))"
        sku = "SKU$(lpad(1 + mod(idx - 1, 2_000), 5, '0'))"
        println(buffer, "$wh,$sku,$(100 + mod(idx, 500)),0,$(mod(idx, 25)),$(20 + mod(idx, 40)),2026-05-26T00:00:00")
    end
    return String(take!(buffer))
end

function csv_import_benchmark_row_count(csv::AbstractString)::Int
    lines = split(chomp(csv), '\n')
    return max(length(lines) - 1, 0)
end

function dashboard_lcp_benchmark_pages()::Vector{String}
    return ["/dashboard", "/imports", "/simulations", "/notifications", "/integrations"]
end
