mutable struct RequestCache
    values::Dict{Symbol,Any}
end

RequestCache() = RequestCache(Dict{Symbol,Any}())

function get_cached!(loader::Function, cache::RequestCache, key::Symbol)
    if haskey(cache.values, key)
        return cache.values[key]
    end

    value = loader()
    cache.values[key] = value
    return value
end

function cache_keys(cache::RequestCache)::Set{Symbol}
    return Set(keys(cache.values))
end
