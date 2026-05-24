const IMPORT_JOB_TYPES = Set(["warehouses", "skus", "inventory", "demand", "lanes"])
const IMPORT_REQUIRED_HEADERS = Dict(
    "warehouses" => ["code", "name", "region", "capacity_units"],
    "skus" => ["sku_code", "name", "category"],
    "inventory" => ["warehouse_code", "sku_code", "on_hand_units"],
    "demand" => ["warehouse_code", "sku_code", "period_start", "period_end", "demand_units"],
    "lanes" => ["from_warehouse_code", "to_warehouse_code", "lead_time_days"],
)

function _import_job_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        import_type = String(row[:import_type]),
        status = String(row[:status]),
        original_filename = String(row[:original_filename]),
        file_path = String(row[:file_path]),
        row_count = Int(row[:row_count]),
        error_report = get(row, :error_report, NamedTuple[]),
        committed_rows = Int(get(row, :committed_rows, 0)),
    )
end

function _validate_import_type(import_type)::String
    value = strip(String(import_type))
    value in IMPORT_JOB_TYPES || throw(ApiError("VALIDATION_ERROR", "import_type is invalid"; status = 400))
    return value
end

function _safe_filename(filename)::String
    cleaned = replace(basename(String(filename)), r"[^A-Za-z0-9_.-]" => "_")
    isempty(cleaned) && throw(ApiError("VALIDATION_ERROR", "original_filename is required"; status = 400))
    return cleaned
end

function _csv_rows(content::AbstractString)::Tuple{Vector{String},Vector{Tuple{Int,Dict{String,String}}}}
    lines = split(replace(content, "\r\n" => "\n"), '\n')
    while !isempty(lines) && isempty(strip(last(lines)))
        pop!(lines)
    end
    isempty(lines) && throw(ApiError("VALIDATION_ERROR", "CSV file is empty"; status = 400))
    headers = [strip(header) for header in split(first(lines), ',')]
    rows = Tuple{Int,Dict{String,String}}[]
    for (offset, line) in enumerate(lines[2:end])
        isempty(strip(line)) && continue
        values = [strip(value) for value in split(line, ',')]
        mapped = Dict{String,String}()
        for (idx, header) in enumerate(headers)
            mapped[header] = idx <= length(values) ? values[idx] : ""
        end
        push!(rows, (offset + 1, mapped))
    end
    return headers, rows
end

function _row_error(row::Int, field::AbstractString, code::AbstractString, message::AbstractString)::NamedTuple
    return (row = row, field = String(field), code = String(code), message = String(message))
end

function _parse_import_decimal(value::AbstractString, field::AbstractString, rownum::Int, errors::Vector{NamedTuple})
    parsed = tryparse(Float64, strip(value))
    if parsed === nothing
        push!(errors, _row_error(rownum, field, "INVALID_NUMBER", "$field must be numeric"))
        return nothing
    elseif parsed < 0
        push!(errors, _row_error(rownum, field, "NEGATIVE_INVENTORY", "$field must be non-negative"))
        return nothing
    end
    return parsed
end

function _required_import_text(row::Dict{String,String}, key::AbstractString, rownum::Int, errors::Vector{NamedTuple})::String
    value = strip(get(row, String(key), ""))
    isempty(value) && push!(errors, _row_error(rownum, key, "REQUIRED", "$key is required"))
    return value
end

function _optional_import_decimal(row::Dict{String,String}, key::AbstractString, default, rownum::Int, errors::Vector{NamedTuple})
    value = strip(get(row, String(key), ""))
    isempty(value) && return default
    return _parse_import_decimal(value, key, rownum, errors)
end

function _parse_import_int(row::Dict{String,String}, key::AbstractString, default, rownum::Int, errors::Vector{NamedTuple})
    value = strip(get(row, String(key), ""))
    isempty(value) && return default
    parsed = tryparse(Int, value)
    if parsed === nothing
        push!(errors, _row_error(rownum, key, "INVALID_INTEGER", "$key must be an integer"))
        return nothing
    elseif parsed < 0
        push!(errors, _row_error(rownum, key, "NEGATIVE_NUMBER", "$key must be non-negative"))
        return nothing
    end
    return parsed
end

function _parse_import_date(row::Dict{String,String}, key::AbstractString, rownum::Int, errors::Vector{NamedTuple})
    value = _required_import_text(row, key, rownum, errors)
    isempty(value) && return nothing
    parsed = tryparse(Date, value)
    parsed === nothing && push!(errors, _row_error(rownum, key, "INVALID_DATE", "$key must be an ISO date"))
    return parsed
end

function _parse_import_bool(row::Dict{String,String}, key::AbstractString, default, rownum::Int, errors::Vector{NamedTuple})
    value = strip(get(row, String(key), ""))
    isempty(value) && return default
    lowered = lowercase(value)
    lowered in ("true", "1", "yes", "active") && return true
    lowered in ("false", "0", "no", "inactive") && return false
    push!(errors, _row_error(rownum, key, "INVALID_BOOLEAN", "$key must be true or false"))
    return nothing
end

function _validate_import_headers(import_type::AbstractString, headers::Vector{String})::Nothing
    required = IMPORT_REQUIRED_HEADERS[String(import_type)]
    missing_headers = [header for header in required if !(header in headers)]
    isempty(missing_headers) || throw(ApiError("VALIDATION_ERROR", "CSV headers are invalid"; status = 400, details = [(missing = missing_headers,)]))
    return nothing
end

function _enforce_import_size!(config::AppConfig, content::AbstractString)::Nothing
    max_bytes = config.imports.max_import_mb * 1024 * 1024
    if sizeof(String(content)) > max_bytes
        throw(ApiError("PAYLOAD_TOO_LARGE", "CSV import exceeds MAX_IMPORT_MB"; status = 413, details = [(max_import_mb = config.imports.max_import_mb,)]))
    end
    return nothing
end
