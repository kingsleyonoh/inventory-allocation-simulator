mutable struct SqlTenantAdminStore <: AbstractTenantAdminStore
    connection::LibPQ.Connection
end

function _payload_get(payload, key::AbstractString, default = nothing)
    sym = Symbol(key)
    if payload isa AbstractDict
        haskey(payload, key) && return payload[key]
        haskey(payload, sym) && return payload[sym]
        return default
    end
    sym in propertynames(payload) && return getproperty(payload, sym)
    return default
end

function _required_text(payload, key::AbstractString)::String
    value = _payload_get(payload, key, nothing)
    value === nothing && throw(ApiError("VALIDATION_ERROR", "$key is required"; status = 400))
    text = strip(String(value))
    isempty(text) && throw(ApiError("VALIDATION_ERROR", "$key is required"; status = 400))
    return text
end

function _optional_text(payload, key::AbstractString)::Union{Nothing,String}
    value = _payload_get(payload, key, nothing)
    value === nothing && return nothing
    text = strip(String(value))
    isempty(text) && throw(ApiError("VALIDATION_ERROR", "$key cannot be blank"; status = 400))
    return text
end

function _optional_bool(payload, key::AbstractString)::Union{Nothing,Bool}
    value = _payload_get(payload, key, nothing)
    value === nothing && return nothing
    value isa Bool && return value
    lowered = lowercase(strip(String(value)))
    lowered in ("true", "1", "yes") && return true
    lowered in ("false", "0", "no") && return false
    throw(ApiError("VALIDATION_ERROR", "$key must be true or false"; status = 400))
end

function _json_payload_value(payload, key::AbstractString, current)
    value = _payload_get(payload, key, nothing)
    value === nothing && return current
    return value
end

_is_nullish(value)::Bool = value === nothing || value === missing
_nullable_text(value)::Union{Nothing,String} = _is_nullish(value) ? nothing : String(value)

function _tenant_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        name = String(row[:name]),
        legal_name = String(row[:legal_name]),
        full_legal_name = String(row[:full_legal_name]),
        display_name = String(row[:display_name]),
        address = row[:address],
        registration = row[:registration],
        contact = row[:contact],
        wordmark = _nullable_text(row[:wordmark]),
    )
end

function _user_response(row)::NamedTuple
    return (
        id = string(row[:id]),
        tenant_id = string(row[:tenant_id]),
        email = String(row[:email]),
        name = String(row[:name]),
        role = String(row[:role]),
        is_active = Bool(row[:is_active]),
    )
end

function _validate_role(role::AbstractString)::String
    value = strip(String(role))
    value in VALID_TENANT_ROLES || throw(ApiError("VALIDATION_ERROR", "role must be admin, planner, or viewer"; status = 400))
    return value
end

function _tenant_admin_uuid_value(value)::UUID
    value isa UUID && return value
    try
        return UUID(strip(String(value)))
    catch err
        err isa ArgumentError || rethrow(err)
        throw(ApiError("VALIDATION_ERROR", "UUID value is malformed"; status = 400))
    end
end
