using JSON3

struct AuthzError <: Exception
    code::String
    message::String
    status::Int
    policy_key::String
end

function AuthzError(policy_key::AbstractString; message::AbstractString = "Forbidden")::AuthzError
    return AuthzError("FORBIDDEN", String(message), 403, String(policy_key))
end

function Base.showerror(io::IO, err::AuthzError)
    print(io, err.code, ": ", err.message)
end

function endpoint_error_response(err::AuthzError; request_id::Union{Nothing,AbstractString} = nothing)
    headers = Dict{String,String}()
    request_id !== nothing && (headers["X-Request-ID"] = String(request_id))
    body = format_error_response(err.code, err.message; details = [(policy = err.policy_key,)], request_id = request_id)
    return request_id === nothing ? (err.status, JSON3.write(body)) : (err.status, JSON3.write(body), headers)
end

struct AuthzPolicy
    key::String
    role::String
    resource::String
    action::String
    allowed::Bool
    reason::Union{Nothing,String}
end

struct AuthorizationRegistry
    source::String
    policies::Dict{String,AuthzPolicy}
end

const AUTHZ_REGISTRY_PATH = joinpath(project_root(), "config", "authz_matrix.json")
const AUTHZ_REGISTRY_CACHE = Ref{Union{Nothing,AuthorizationRegistry}}(nothing)

function _authz_string(value)::String
    return String(value)
end

function _authz_policy(entry)::AuthzPolicy
    reason = haskey(entry, :reason) ? String(entry[:reason]) : nothing
    return AuthzPolicy(
        _authz_string(entry[:key]),
        _authz_string(entry[:role]),
        _authz_string(entry[:resource]),
        _authz_string(entry[:action]),
        Bool(entry[:allowed]),
        reason,
    )
end

function load_authz_registry(path::AbstractString = AUTHZ_REGISTRY_PATH)::AuthorizationRegistry
    matrix = JSON3.read(read(path, String))
    policies = Dict{String,AuthzPolicy}()
    for entry in matrix[:policies]
        policy = _authz_policy(entry)
        policies[policy.key] = policy
    end
    return AuthorizationRegistry(String(matrix[:source]), policies)
end

function default_authz_registry()::AuthorizationRegistry
    cached = AUTHZ_REGISTRY_CACHE[]
    cached !== nothing && return cached
    registry = load_authz_registry()
    AUTHZ_REGISTRY_CACHE[] = registry
    return registry
end

policy_key(role::AbstractString, resource::AbstractString, action::AbstractString)::String =
    string(role, ":", resource, ":", action)

const METRICS_READINESS_RESOURCE = "metrics_readiness"
const METRICS_READINESS_READ_ACTION = "read"

function authorize_metrics_readiness!(
    ctx::TenantContext;
    registry::AuthorizationRegistry = default_authz_registry(),
)::TenantContext
    return authorize!(ctx, METRICS_READINESS_READ_ACTION, METRICS_READINESS_RESOURCE; registry = registry)
end

function authorize!(
    ctx::TenantContext,
    action::AbstractString,
    resource::AbstractString;
    registry::AuthorizationRegistry = default_authz_registry(),
)::TenantContext
    require_tenant_context(ctx)
    key = policy_key(ctx.role, resource, action)
    policy = get(registry.policies, key, nothing)
    if policy === nothing || !policy.allowed
        reason = policy === nothing ? "Authorization policy is not registered" : "Role is not permitted for this action"
        throw(AuthzError(key; message = reason))
    end
    return ctx
end
