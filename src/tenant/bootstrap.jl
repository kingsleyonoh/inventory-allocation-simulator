using Dates
using LibPQ
using Random
using SHA
using UUIDs

abstract type AbstractSetupStore end

struct SetupResult
    status::Symbol
    message::String
    api_key::Union{Nothing,String}
    api_key_hash::Union{Nothing,String}
end

mutable struct SqlSetupStore <: AbstractSetupStore
    connection::LibPQ.Connection
end

SqlSetupStore(database_url::AbstractString) = SqlSetupStore(LibPQ.Connection(String(database_url)))

count_tenants(::AbstractSetupStore) = throw(ArgumentError("count_tenants is not implemented for this setup store"))
insert_tenant!(::AbstractSetupStore, _tenant) = throw(ArgumentError("insert_tenant! is not implemented for this setup store"))
insert_admin_user!(::AbstractSetupStore, _user) = throw(ArgumentError("insert_admin_user! is not implemented for this setup store"))
ensure_bootstrap_schema!(::AbstractSetupStore) = nothing

function close!(store::SqlSetupStore)::Nothing
    close(store.connection)
    return nothing
end

function ensure_bootstrap_schema!(store::SqlSetupStore)::Nothing
    LibPQ.execute(store.connection, """
        CREATE TABLE IF NOT EXISTS tenants (
            id UUID PRIMARY KEY,
            name TEXT NOT NULL,
            legal_name TEXT NOT NULL,
            full_legal_name TEXT NOT NULL,
            display_name TEXT NOT NULL,
            address JSONB NOT NULL DEFAULT '{}',
            registration JSONB NOT NULL DEFAULT '{}',
            contact JSONB NOT NULL DEFAULT '{}',
            wordmark TEXT NULL,
            api_key_hash TEXT NOT NULL UNIQUE,
            is_active BOOLEAN NOT NULL DEFAULT true,
            created_at TIMESTAMP NOT NULL DEFAULT now(),
            updated_at TIMESTAMP NOT NULL DEFAULT now()
        )
    """)
    LibPQ.execute(store.connection, """
        CREATE TABLE IF NOT EXISTS users (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES tenants(id),
            email TEXT NOT NULL,
            name TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('admin','planner','viewer')),
            is_active BOOLEAN NOT NULL DEFAULT true,
            created_at TIMESTAMP NOT NULL DEFAULT now(),
            updated_at TIMESTAMP NOT NULL DEFAULT now(),
            UNIQUE (tenant_id, email)
        )
    """)
    return nothing
end

function count_tenants(store::SqlSetupStore)::Int
    result = LibPQ.execute(store.connection, "SELECT COUNT(*) FROM tenants")
    row = first(result)
    return Int(row[1])
end

function insert_tenant!(store::SqlSetupStore, tenant)
    LibPQ.execute(store.connection, """
        INSERT INTO tenants (id, name, legal_name, full_legal_name, display_name, api_key_hash)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6)
    """, [string(tenant.id), tenant.name, tenant.legal_name, tenant.full_legal_name, tenant.display_name, tenant.api_key_hash])
    return tenant.id
end

function insert_admin_user!(store::SqlSetupStore, user)
    LibPQ.execute(store.connection, """
        INSERT INTO users (id, tenant_id, email, name, role)
        VALUES (\$1, \$2, \$3, \$4, \$5)
        ON CONFLICT (tenant_id, email) DO NOTHING
    """, [string(user.id), string(user.tenant_id), user.email, user.name, user.role])
    return user.id
end

function _secure_random_bytes(length::Int)::Vector{UInt8}
    return rand(RandomDevice(), UInt8, length)
end

function generate_api_key(prefix::AbstractString; key_material = nothing)::String
    suffix = if key_material === nothing
        bytes2hex(_secure_random_bytes(18))
    else
        bytes2hex(sha256(String(key_material)))[1:36]
    end
    return string(prefix, "_", suffix)
end

hash_api_key(raw_key::AbstractString)::String = bytes2hex(sha256(String(raw_key)))

function _tenant_row(config::AppConfig, tenant_id::UUID, api_key_hash::String)
    name = config.tenant.default_tenant_name
    return (
        id = tenant_id,
        name = name,
        legal_name = name,
        full_legal_name = name,
        display_name = name,
        api_key_hash = api_key_hash,
    )
end

function _admin_row(config::AppConfig, tenant_id::UUID)
    email = config.tenant.default_admin_email
    return (
        id = uuid4(),
        tenant_id = tenant_id,
        email = email,
        name = email,
        role = "admin",
    )
end

function _first_run_setup_core!(store::AbstractSetupStore, config::AppConfig; key_material = nothing)::SetupResult
    ensure_bootstrap_schema!(store)
    if count_tenants(store) > 0
        return SetupResult(:already_initialized, "Already initialized", nothing, nothing)
    end

    raw_key = generate_api_key(config.tenant.api_key_prefix; key_material = key_material)
    key_hash = hash_api_key(raw_key)
    tenant_id = uuid4()
    insert_tenant!(store, _tenant_row(config, tenant_id, key_hash))

    if !isempty(strip(config.tenant.default_admin_email))
        insert_admin_user!(store, _admin_row(config, tenant_id))
    end

    return SetupResult(:created, "First-run setup complete.", raw_key, key_hash)
end

function first_run_setup!(store::AbstractSetupStore, config::AppConfig; key_material = nothing)::SetupResult
    return _first_run_setup_core!(store, config; key_material = key_material)
end

function first_run_setup!(store::SqlSetupStore, config::AppConfig; key_material = nothing)::SetupResult
    ensure_bootstrap_schema!(store)
    LibPQ.execute(store.connection, "BEGIN")
    try
        result = count_tenants(store) > 0 ?
            SetupResult(:already_initialized, "Already initialized", nothing, nothing) :
            _first_run_setup_core!(store, config; key_material = key_material)
        LibPQ.execute(store.connection, "COMMIT")
        return result
    catch err
        LibPQ.execute(store.connection, "ROLLBACK")
        rethrow(err)
    end
end

function run_setup_cli(args = ARGS)::Int
    if "--help" in args || "-h" in args
        println("Usage: julia --project scripts/setup.jl")
        return 0
    end

    load_env_file!()
    config = load_config(ENV)
    store = SqlSetupStore(config.database.url)
    try
        result = first_run_setup!(store, config)
        println(result.message)
        if result.status == :created
            println("Your API Key: ", result.api_key)
            println("Use this in the X-API-Key header for API requests.")
        end
        return 0
    finally
        close!(store)
    end
end
