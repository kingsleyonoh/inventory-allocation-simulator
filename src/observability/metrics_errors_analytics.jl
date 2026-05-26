using Dates
using UUIDs

include("metrics_collectors.jl")
include("metrics_prometheus.jl")

const OBSERVABILITY_KEY_EVENTS = Set([
    "tenant_registered",
    "import_completed",
    "simulation_started",
    "simulation_completed",
    "recommendation_approved",
    "recommendation_exported",
])

function _observability_require_text(value::AbstractString, field::AbstractString)::String
    cleaned = strip(String(value))
    isempty(cleaned) && throw(ApiError("VALIDATION_ERROR", "$field is required"; status = 400))
    return cleaned
end

function normalized_observability_event_type(event_type::AbstractString)::String
    lowered = lowercase(strip(String(event_type)))
    return replace(lowered, r"[\.\s]+" => "_")
end

function ready_health_response(
    services::AppServices;
    migration_dir::AbstractString = joinpath(project_root(), "migrations"),
    migration_store::Union{Nothing,AbstractMigrationStore} = nothing,
)
    database = db_health_response(services; migration_dir = migration_dir, migration_store = migration_store)
    ready = database.status == "ok"
    return (status = ready ? "ready" : "not_ready", service = "inventory-allocation-simulator", database = database)
end

function build_local_error_event(
    event_type::AbstractString;
    tenant_id::Union{Nothing,UUID} = nothing,
    source::AbstractString,
    message::AbstractString,
    request_id::Union{Nothing,AbstractString} = nothing,
    details::AbstractDict = Dict{String,Any}(),
    occurred_at::DateTime = Dates.now(),
)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => uuid4(),
        :tenant_id => tenant_id,
        :event_type => _observability_require_text(event_type, "event_type"),
        :source => _observability_require_text(source, "source"),
        :message => _observability_require_text(message, "message"),
        :request_id => request_id === nothing ? nothing : String(request_id),
        :details => Dict{String,Any}(String(key) => value for (key, value) in details),
        :occurred_at => occurred_at,
    )
end

function build_local_analytics_event(
    event_type::AbstractString;
    tenant_id::Union{Nothing,UUID} = nothing,
    user_id::Union{Nothing,UUID} = nothing,
    properties::AbstractDict = Dict{String,Any}(),
    occurred_at::DateTime = Dates.now(),
)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => uuid4(),
        :tenant_id => tenant_id,
        :user_id => user_id,
        :event_type => normalized_observability_event_type(_observability_require_text(event_type, "event_type")),
        :properties => Dict{String,Any}(String(key) => value for (key, value) in properties),
        :occurred_at => occurred_at,
    )
end

function record_local_error_event!(store::SqlTenantAdminStore, event::AbstractDict)::UUID
    id = get(event, :id, uuid4())
    tenant_id = get(event, :tenant_id, nothing)
    params = [
        string(id),
        tenant_id === nothing ? missing : string(tenant_id),
        String(get(event, :event_type, "")),
        String(get(event, :source, "")),
        String(get(event, :message, "")),
        get(event, :request_id, nothing) === nothing ? missing : String(event[:request_id]),
        JSON3.write(get(event, :details, Dict{String,Any}())),
    ]
    LibPQ.execute(store.connection, """
        INSERT INTO local_error_events (id, tenant_id, event_type, source, message, request_id, details)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7::jsonb)
    """, params)
    return id
end

function record_local_analytics_event!(store::SqlTenantAdminStore, event::AbstractDict)::UUID
    id = get(event, :id, uuid4())
    tenant_id = get(event, :tenant_id, nothing)
    user_id = get(event, :user_id, nothing)
    params = [
        string(id),
        tenant_id === nothing ? missing : string(tenant_id),
        user_id === nothing ? missing : string(user_id),
        String(get(event, :event_type, "")),
        JSON3.write(get(event, :properties, Dict{String,Any}())),
    ]
    LibPQ.execute(store.connection, """
        INSERT INTO local_analytics_events (id, tenant_id, user_id, event_type, properties)
        VALUES (\$1, \$2, \$3, \$4, \$5::jsonb)
    """, params)
    return id
end
