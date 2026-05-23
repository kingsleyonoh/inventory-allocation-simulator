using Dates
using LibPQ

struct Migration
    version::String
    name::String
    up_path::String
    down_path::Union{Nothing,String}
end

struct MigrationRunResult
    direction::Symbol
    applied_versions::Vector{String}
end

struct MigrationHealth
    status::Symbol
    current_version::Union{Nothing,String}
    pending_versions::Vector{String}
end

abstract type AbstractMigrationStore end

mutable struct MemoryMigrationStore <: AbstractMigrationStore
    applied::Vector{String}
    executed_sql::Vector{String}
end

MemoryMigrationStore() = MemoryMigrationStore(String[], String[])

struct SqlMigrationStore <: AbstractMigrationStore
    connection::LibPQ.Connection
end

SqlMigrationStore(database_url::AbstractString) = SqlMigrationStore(LibPQ.Connection(String(database_url)))

function close!(store::SqlMigrationStore)::Nothing
    close(store.connection)
    return nothing
end

function _migration_parts(filename::AbstractString)
    match_result = match(r"^(\d+)_(.+)\.(up|down)\.sql$", String(filename))
    match_result === nothing && return nothing
    return (version = match_result.captures[1], name = match_result.captures[2], direction = Symbol(match_result.captures[3]))
end

function discover_migrations(dir::AbstractString = joinpath(project_root(), "migrations"))::Vector{Migration}
    isdir(dir) || throw(ArgumentError("migration directory does not exist: $dir"))
    grouped = Dict{String,Dict{Symbol,String}}()
    names = Dict{String,String}()

    for filename in sort(readdir(dir))
        parts = _migration_parts(filename)
        parts === nothing && continue
        key = parts.version
        names[key] = parts.name
        direction_paths = get!(grouped, key, Dict{Symbol,String}())
        direction_paths[parts.direction] = joinpath(dir, filename)
    end

    migrations = Migration[]
    for version in sort(collect(keys(grouped)))
        paths = grouped[version]
        haskey(paths, :up) || throw(ArgumentError("migration $version is missing an up SQL file"))
        push!(migrations, Migration(version, names[version], paths[:up], get(paths, :down, nothing)))
    end
    return migrations
end

function ensure_migrations_table!(::MemoryMigrationStore)::Nothing
    return nothing
end

function ensure_migrations_table!(store::SqlMigrationStore)::Nothing
    LibPQ.execute(store.connection, """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TIMESTAMP NOT NULL DEFAULT now()
        )
    """)
    return nothing
end

function applied_versions(store::MemoryMigrationStore)::Vector{String}
    return copy(store.applied)
end

function applied_versions(store::SqlMigrationStore)::Vector{String}
    ensure_migrations_table!(store)
    result = LibPQ.execute(store.connection, "SELECT version FROM schema_migrations ORDER BY version ASC")
    return [String(row[1]) for row in result]
end

function apply_migration_sql!(store::MemoryMigrationStore, sql::String)::Nothing
    push!(store.executed_sql, sql)
    return nothing
end

function apply_migration_sql!(store::SqlMigrationStore, sql::String)::Nothing
    isempty(strip(sql)) && return nothing
    LibPQ.execute(store.connection, sql)
    return nothing
end

function record_migration!(store::MemoryMigrationStore, migration::Migration)::Nothing
    migration.version in store.applied || push!(store.applied, migration.version)
    sort!(store.applied)
    return nothing
end

function record_migration!(store::SqlMigrationStore, migration::Migration)::Nothing
    LibPQ.execute(
        store.connection,
        "INSERT INTO schema_migrations (version, name) VALUES (\$1, \$2) ON CONFLICT (version) DO NOTHING",
        [migration.version, migration.name],
    )
    return nothing
end

function delete_migration!(store::MemoryMigrationStore, migration::Migration)::Nothing
    filter!(version -> version != migration.version, store.applied)
    return nothing
end

function delete_migration!(store::SqlMigrationStore, migration::Migration)::Nothing
    LibPQ.execute(store.connection, "DELETE FROM schema_migrations WHERE version = \$1", [migration.version])
    return nothing
end

function _apply_one_migration_unwrapped!(store::AbstractMigrationStore, migration::Migration, direction::Symbol)::Nothing
    sql_path = direction == :up ? migration.up_path : migration.down_path
    sql_path === nothing && throw(ArgumentError("migration $(migration.version) has no down SQL file"))
    sql = read(sql_path, String)
    apply_migration_sql!(store, sql)
    direction == :up ? record_migration!(store, migration) : delete_migration!(store, migration)
    return nothing
end

function _run_one_migration!(store::AbstractMigrationStore, migration::Migration, direction::Symbol)::Nothing
    _apply_one_migration_unwrapped!(store, migration, direction)
    return nothing
end

function _run_one_migration!(store::SqlMigrationStore, migration::Migration, direction::Symbol)::Nothing
    LibPQ.execute(store.connection, "BEGIN")
    try
        _apply_one_migration_unwrapped!(store, migration, direction)
        LibPQ.execute(store.connection, "COMMIT")
    catch err
        LibPQ.execute(store.connection, "ROLLBACK")
        rethrow(err)
    end
    return nothing
end

function run_migrations!(store::AbstractMigrationStore, dir::AbstractString = joinpath(project_root(), "migrations"); direction::Symbol = :up)::MigrationRunResult
    direction in (:up, :down) || throw(ArgumentError("migration direction must be :up or :down"))
    ensure_migrations_table!(store)
    migrations = discover_migrations(dir)
    applied = Set(applied_versions(store))

    plan = if direction == :up
        [migration for migration in migrations if !(migration.version in applied)]
    else
        reverse([migration for migration in migrations if migration.version in applied])
    end

    applied_now = String[]
    for migration in plan
        _run_one_migration!(store, migration, direction)
        push!(applied_now, migration.version)
    end
    return MigrationRunResult(direction, applied_now)
end

function migration_health(store::AbstractMigrationStore, dir::AbstractString = joinpath(project_root(), "migrations"))::MigrationHealth
    ensure_migrations_table!(store)
    migrations = discover_migrations(dir)
    applied = Set(applied_versions(store))
    pending = [migration.version for migration in migrations if !(migration.version in applied)]
    current = isempty(applied) ? nothing : maximum(collect(applied))
    return MigrationHealth(isempty(pending) ? :current : :pending, current, pending)
end

function run_migrate_cli(args = ARGS)::Int
    if "--help" in args || "-h" in args
        println("Usage: julia --project scripts/migrate.jl [up|down]")
        return 0
    end

    direction_arg = isempty(args) ? "up" : first(args)
    if !(direction_arg in ("up", "down"))
        println(stderr, "Invalid migration direction: $direction_arg. Use up or down.")
        return 2
    end

    load_env_file!()
    config = load_config(ENV)
    store = SqlMigrationStore(config.database.url)
    try
        result = run_migrations!(store; direction = Symbol(direction_arg))
        println("Migrations $(direction_arg) complete: ", isempty(result.applied_versions) ? "none" : join(result.applied_versions, ","))
        return 0
    finally
        close!(store)
    end
end
