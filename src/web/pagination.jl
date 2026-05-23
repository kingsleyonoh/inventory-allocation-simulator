const DEFAULT_PAGE_SIZE = 25
const MAX_PAGE_SIZE = 250
const RESERVED_PAGINATION_PARAMS = Set(["limit", "cursor"])

struct CursorPageRequest
    limit::Int
    cursor::Union{Nothing,String}
    filters::Dict{String,String}
end

function _parse_limit(params::AbstractDict)::Int
    raw = get(params, "limit", string(DEFAULT_PAGE_SIZE))
    parsed = tryparse(Int, string(raw))
    if parsed === nothing || parsed < 1 || parsed > MAX_PAGE_SIZE
        throw(ApiError("VALIDATION_ERROR", "limit must be between 1 and $MAX_PAGE_SIZE"; status = 400))
    end
    return parsed
end

function parse_cursor_params(
    params::AbstractDict;
    allowed_filters::Set{String} = Set(["warehouse_id", "sku_id", "status", "created_after", "created_before", "category", "region"]),
)::CursorPageRequest
    limit = _parse_limit(params)
    cursor = haskey(params, "cursor") ? string(params["cursor"]) : nothing
    filters = Dict{String,String}()
    for (key, value) in params
        key_string = string(key)
        key_string in RESERVED_PAGINATION_PARAMS && continue
        if !(key_string in allowed_filters)
            throw(ApiError("VALIDATION_ERROR", "unsupported filter: $key_string"; status = 400))
        end
        filters[key_string] = string(value)
    end
    return CursorPageRequest(limit, cursor, filters)
end

function cursor_where_clause(page::CursorPageRequest; alias::AbstractString = "")::Union{Nothing,String}
    page.cursor === nothing && return nothing
    prefix = isempty(alias) ? "" : string(alias, ".")
    return string("(", prefix, "created_at, ", prefix, "id) < (\$cursor_created_at, \$cursor_id)")
end
