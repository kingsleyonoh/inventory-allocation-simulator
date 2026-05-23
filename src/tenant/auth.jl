using Dates
using SHA
using UUIDs

abstract type AbstractAuthStore end

struct AuthError <: Exception
    code::String
    message::String
    status::Int
end

function AuthError(code::AbstractString, message::AbstractString; status::Int = 401)::AuthError
    return AuthError(String(code), String(message), status)
end

function Base.showerror(io::IO, err::AuthError)
    print(io, err.code, ": ", err.message)
end

function endpoint_error_response(err::AuthError)::Tuple{Int,String}
    body = format_error_response(err.code, err.message; details = Any[])
    return err.status, JSON3.write(body)
end

struct TenantAuthRecord
    tenant_id::UUID
    user_id::Union{Nothing,UUID}
    role::String
    is_active::Bool
end

struct SessionAuthRecord
    tenant_id::UUID
    user_id::UUID
    role::String
    is_active::Bool
    expires_at::DateTime
end

struct AuthRequest
    api_key::Union{Nothing,String}
    session_cookie::Union{Nothing,String}
end

lookup_tenant_by_api_key_hash(::AbstractAuthStore, _api_key_hash::String) = nothing
lookup_session_record(::AbstractAuthStore, _session_id::String) = nothing

function signed_session_cookie(session_id::AbstractString, secret::AbstractString)::String
    signature = bytes2hex(sha256(string(secret, ":", session_id)))
    return string(session_id, ".", signature)
end

function verify_session_cookie(cookie::AbstractString, secret::AbstractString)::String
    parts = split(String(cookie), "."; limit = 2)
    length(parts) == 2 || throw(AuthError("UNAUTHORIZED", "Invalid session"; status = 401))
    expected = signed_session_cookie(parts[1], secret)
    expected == String(cookie) || throw(AuthError("UNAUTHORIZED", "Invalid session"; status = 401))
    return parts[1]
end

function _context_from_api_key(store::AbstractAuthStore, raw_key::String)::TenantContext
    record = lookup_tenant_by_api_key_hash(store, hash_api_key(raw_key))
    record === nothing && throw(AuthError("UNAUTHORIZED", "Invalid API key"; status = 401))
    record.is_active || throw(AuthError("FORBIDDEN", "Tenant is inactive"; status = 403))
    return TenantContext(record.tenant_id; user_id = record.user_id, role = record.role, auth_method = :api_key)
end

function _context_from_session(
    store::AbstractAuthStore,
    cookie::String,
    secret::AbstractString,
    now::Function,
)::TenantContext
    session_id = verify_session_cookie(cookie, secret)
    record = lookup_session_record(store, session_id)
    record === nothing && throw(AuthError("UNAUTHORIZED", "Invalid session"; status = 401))
    record.is_active || throw(AuthError("FORBIDDEN", "Session user is inactive"; status = 403))
    now() <= record.expires_at || throw(AuthError("UNAUTHORIZED", "Session expired"; status = 401))
    return TenantContext(record.tenant_id; user_id = record.user_id, role = record.role, auth_method = :session)
end

function resolve_tenant_context(
    store::AbstractAuthStore,
    request::AuthRequest;
    cache::RequestCache = RequestCache(),
    session_secret::AbstractString = "",
    now::Function = () -> Dates.now(UTC),
)::TenantContext
    return get_cached!(cache, :tenant_context) do
        if request.api_key !== nothing && !isempty(strip(request.api_key))
            return _context_from_api_key(store, request.api_key)
        elseif request.session_cookie !== nothing && !isempty(strip(request.session_cookie))
            isempty(session_secret) && throw(AuthError("UNAUTHORIZED", "Session secret is required"; status = 401))
            return _context_from_session(store, request.session_cookie, session_secret, now)
        end
        throw(AuthError("UNAUTHORIZED", "Authentication required"; status = 401))
    end
end
