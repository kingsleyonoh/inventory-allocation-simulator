using Test
using Dates
using UUIDs
using JSON3
using InventoryAllocationSimulator

function batch051_stockout_fixture_rows()
    fixture = JSON3.read(read(joinpath(project_root(), "tests", "fixtures", "correctness", "forecast_stockout_history.json"), String))
    tenant_id = UUID(String(fixture.tenant_id))
    warehouse_id = UUID("11111111-0000-4111-8111-111111111111")
    sku_id = UUID("22222222-0000-4222-8222-222222222222")
    rows = Dict{Symbol,Any}[]
    for (idx, period) in enumerate(fixture.periods)
        push!(rows, Dict{Symbol,Any}(
            :id => uuid5(UUID("00000000-0000-0000-0000-000000000000"), "batch051-stockout-$idx"),
            :tenant_id => tenant_id,
            :warehouse_id => warehouse_id,
            :sku_id => sku_id,
            :period_start => Date(String(period.period_start)),
            :period_end => Date(String(period.period_end)),
            :demand_units => Float64(period.demand_units),
            :lost_sales_units => Float64(period.lost_sales_units),
            :source => "manual",
        ))
    end
    return fixture, rows
end

@testset "Batch 051 stockout-history fixture treats unavailable inventory as unmet demand" begin
    fixture, rows = batch051_stockout_fixture_rows()
    cleaned = clean_demand_history(rows)
    observed_average = sum(row.observed_units for row in cleaned) / length(cleaned)
    adjusted_average = sum(row.adjusted_units for row in cleaned) / length(cleaned)
    stockout_rows = filter(row -> row.stockout_adjusted, cleaned)
    zero_observed_stockout = only(filter(row -> row.observed_units == 0.0 && row.lost_sales_units > 0.0, cleaned))

    @test String(fixture.derivedFrom) == "docs/inventory-allocation-simulator_prd.md §5.3"
    @test String(fixture.rule) == "lost_sales_units are added to observed demand for stockout-aware cleaning and increase uncertainty"
    @test length(stockout_rows) == 2
    @test zero_observed_stockout.adjusted_units == 50.0
    @test adjusted_average >= Float64(fixture.minimumCleanedDemandAverage)
    @test adjusted_average > observed_average * 1.75

    preview = InventoryAllocationSimulator.forecast_preview_from_snapshot((policy = (id = "batch051-policy", name = "Stockout fixture audit"), demand_history = rows); scenario_count = 4)
    forecast = only(preview.forecasts)
    @test forecast.stockout_periods == 2
    @test forecast.observed_mean_units ≈ observed_average atol = 0.0001
    @test forecast.mean_adjusted_units ≈ adjusted_average atol = 0.0001
    @test forecast.baseline_units >= Float64(fixture.minimumCleanedDemandAverage)
    @test forecast.baseline_units > observed_average * 1.75
    @test forecast.uncertainty_units > 0
end

@testset "Batch 051 stockout-history audit gate is rerunnable" begin
    script = joinpath(project_root(), ".yolo", "scripts", "validate-batch-051-stockout-history-audit.sh")
    @test isfile(script)
    source = isfile(script) ? read(script, String) : ""
    for token in [
        "forecast_stockout_history.json",
        "test_batch051_stockout_history_audit.jl",
        "lost_sales_units",
        "clean_demand_history",
        "forecast_preview_from_snapshot",
        "minimumCleanedDemandAverage",
        "stockout_adjusted",
    ]
        @test occursin(token, source)
    end
end
