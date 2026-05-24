using Dates

struct RateLimitPolicy
    limit::Int
    window_seconds::Int
    name::String
end

struct RateLimitDecision
    allowed::Bool
    remaining::Int
    retry_after_seconds::Int
end

mutable struct MemoryRateLimiter
    hits::Dict{Tuple{String,String},Vector{DateTime}}
    now::Function
end

const FIVE_PER_HOUR_ROUTES = Set{Tuple{String,String}}([
    ("POST", "/api/tenants/register"),
    ("POST", "/api/settings/api-key/rotate"),
])

const TWENTY_PER_MINUTE_ROUTES = Set{Tuple{String,String}}([
    ("POST", "/api/simulations"),
    ("POST", "/api/simulations/:id/cancel"),
    ("GET", "/api/recommendations/export.csv"),
    ("PATCH", "/api/settings/tenant"),
    ("POST", "/api/users"),
    ("PATCH", "/api/users/:id"),
    ("POST", "/api/integrations/test"),
])

const THIRTY_PER_MINUTE_ROUTES = Set{Tuple{String,String}}([
    ("POST", "/api/imports"),
    ("POST", "/api/policies"),
])

const SIXTY_PER_MINUTE_ROUTES = Set{Tuple{String,String}}([
    ("GET", "/api/users"),
    ("POST", "/api/recommendations/:id/approve"),
    ("POST", "/api/recommendations/:id/reject"),
    ("POST", "/api/notifications/:id/read"),
    ("GET", "/api/integrations/status"),
])

MemoryRateLimiter(now::Function = () -> Dates.now(UTC)) = MemoryRateLimiter(Dict{Tuple{String,String},Vector{DateTime}}(), now)

function _window_start(current::DateTime, policy::RateLimitPolicy)::DateTime
    return current - Dates.Second(policy.window_seconds)
end

function check_rate_limit!(limiter::MemoryRateLimiter, identity::AbstractString, policy::RateLimitPolicy)::RateLimitDecision
    current = limiter.now()
    key = (String(identity), policy.name)
    hits = get!(limiter.hits, key, DateTime[])
    cutoff = _window_start(current, policy)
    filter!(timestamp -> timestamp > cutoff, hits)
    if length(hits) >= policy.limit
        retry_after = max(1, Int(ceil((hits[1] + Dates.Second(policy.window_seconds) - current).value / 1000)))
        return RateLimitDecision(false, 0, retry_after)
    end
    push!(hits, current)
    return RateLimitDecision(true, policy.limit - length(hits), 0)
end

function default_rate_limit_policy(method::AbstractString, path::AbstractString)::RateLimitPolicy
    method_name = uppercase(String(method))
    path_name = String(path)
    route = method_name * " " * path_name
    key = (method_name, path_name)

    if key in FIVE_PER_HOUR_ROUTES
        return RateLimitPolicy(5, 3600, route)
    elseif key in TWENTY_PER_MINUTE_ROUTES
        return RateLimitPolicy(20, 60, route)
    elseif key in THIRTY_PER_MINUTE_ROUTES
        return RateLimitPolicy(30, 60, route)
    elseif key in SIXTY_PER_MINUTE_ROUTES
        return RateLimitPolicy(60, 60, route)
    elseif method_name == "GET"
        return RateLimitPolicy(120, 60, route)
    elseif method_name in ("POST", "PUT", "PATCH")
        return RateLimitPolicy(60, 60, route)
    end
    return RateLimitPolicy(120, 60, route)
end
