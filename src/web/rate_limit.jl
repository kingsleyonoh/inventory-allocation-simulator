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
    route = uppercase(String(method)) * " " * String(path)
    if startswith(route, "GET ")
        return RateLimitPolicy(120, 60, route)
    elseif occursin("/api/tenants/register", route) || occursin("/api/settings/api-key/rotate", route)
        return RateLimitPolicy(5, 3600, route)
    elseif startswith(route, "POST ") || startswith(route, "PUT ") || startswith(route, "PATCH ")
        return RateLimitPolicy(60, 60, route)
    end
    return RateLimitPolicy(120, 60, route)
end
