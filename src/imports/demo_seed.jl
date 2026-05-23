struct DemoFixtureManifest
    valid::Bool
    row_counts::Dict{String,Int}
    files::Vector{String}
end

const DEMO_CSV_HEADERS = Dict(
    "warehouses.csv" => ["code", "name", "region", "capacity_units", "handling_cost_cents"],
    "skus.csv" => ["sku_code", "name", "category", "unit_volume", "unit_margin_cents", "stockout_cost_cents", "holding_cost_cents"],
    "inventory.csv" => ["warehouse_code", "sku_code", "on_hand_units", "reserved_units", "inbound_units", "safety_stock_units", "as_of", "source"],
    "demand_history.csv" => ["warehouse_code", "sku_code", "period_start", "period_end", "demand_units", "lost_sales_units", "source"],
    "transfer_lanes.csv" => ["from_warehouse_code", "to_warehouse_code", "lead_time_days", "cost_per_unit_cents", "capacity_units_day"],
)

function _csv_columns(line::AbstractString)::Vector{String}
    return strip.(split(strip(line), ","))
end

function validate_demo_fixtures(dir::AbstractString = joinpath(project_root(), "tests", "fixtures", "csv"))::DemoFixtureManifest
    row_counts = Dict{String,Int}()
    files = sort(collect(keys(DEMO_CSV_HEADERS)))

    for file in files
        path = joinpath(dir, file)
        isfile(path) || throw(ArgumentError("missing demo CSV fixture: $file"))
        lines = readlines(path)
        length(lines) >= 2 || throw(ArgumentError("demo CSV fixture $file must include a header and at least one data row"))
        header = _csv_columns(first(lines))
        expected = DEMO_CSV_HEADERS[file]
        header == expected || throw(ArgumentError("demo CSV fixture $file has invalid header $(join(header, ",")); expected $(join(expected, ","))"))
        row_counts[file] = count(line -> !isempty(strip(line)), lines[2:end])
    end

    return DemoFixtureManifest(true, row_counts, files)
end

function run_seed_demo_cli(args = ARGS)::Int
    fixture_dir = isempty(args) ? joinpath(project_root(), "tests", "fixtures", "csv") : first(args)
    manifest = validate_demo_fixtures(fixture_dir)
    println("Demo CSV fixtures valid.")
    for file in manifest.files
        println(file, ": ", manifest.row_counts[file], " rows")
    end
    return 0
end
