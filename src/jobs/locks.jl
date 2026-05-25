using SHA

const MEMORY_ADVISORY_LOCKS = Set{String}()

function advisory_lock_key(parts...)::String
    return bytes2hex(sha256(join(string.(parts), ":")))[1:16]
end

function with_advisory_lock!(store::AbstractTenantAdminStore, key::AbstractString, fn::Function)
    if key in MEMORY_ADVISORY_LOCKS
        return nothing
    end
    push!(MEMORY_ADVISORY_LOCKS, String(key))
    try
        return fn()
    finally
        delete!(MEMORY_ADVISORY_LOCKS, String(key))
    end
end

with_advisory_lock!(fn::Function, store::AbstractTenantAdminStore, key::AbstractString) =
    with_advisory_lock!(store, key, fn)

function _postgres_advisory_lock_id(key::AbstractString)::Int64
    return reinterpret(Int64, UInt64(hash(String(key))))
end

function with_advisory_lock!(store::SqlTenantAdminStore, key::AbstractString, fn::Function)
    hashed = _postgres_advisory_lock_id(key)
    acquired = first(LibPQ.execute(store.connection, "SELECT pg_try_advisory_lock(\$1)", [hashed]))[1]
    acquired || return nothing
    try
        return fn()
    finally
        LibPQ.execute(store.connection, "SELECT pg_advisory_unlock(\$1)", [hashed])
    end
end
