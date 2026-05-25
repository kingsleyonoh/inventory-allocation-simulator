
abstract type AbstractTenantAdminStore <: AbstractAuthStore end

mutable struct MemoryTenantAdminStore <: AbstractTenantAdminStore
    tenants::Dict{UUID,Dict{Symbol,Any}}
    users::Dict{UUID,Dict{Symbol,Any}}
    warehouses::Dict{UUID,Dict{Symbol,Any}}
    skus::Dict{UUID,Dict{Symbol,Any}}
    inventory_positions::Dict{UUID,Dict{Symbol,Any}}
    demand_history::Dict{UUID,Dict{Symbol,Any}}
    transfer_lanes::Dict{UUID,Dict{Symbol,Any}}
    allocation_policies::Dict{UUID,Dict{Symbol,Any}}
    import_jobs::Dict{UUID,Dict{Symbol,Any}}
    simulation_runs::Dict{UUID,Dict{Symbol,Any}}
    demand_scenarios::Dict{UUID,Dict{Symbol,Any}}
    allocation_recommendations::Dict{UUID,Dict{Symbol,Any}}
    recommendation_decisions::Dict{UUID,Dict{Symbol,Any}}
    simulation_idempotency::Dict{Tuple{UUID,String},UUID}
end

function _record_map(records::AbstractVector)::Dict{UUID,Dict{Symbol,Any}}
    mapped = Dict{UUID,Dict{Symbol,Any}}()
    for record in records
        mapped[record.id] = Dict{Symbol,Any}(name => getproperty(record, name) for name in propertynames(record))
    end
    return mapped
end

function MemoryTenantAdminStore(
    tenants::AbstractVector,
    users::AbstractVector;
    warehouses::AbstractVector = [],
    skus::AbstractVector = [],
    inventory_positions::AbstractVector = [],
    demand_history::AbstractVector = [],
    transfer_lanes::AbstractVector = [],
    allocation_policies::AbstractVector = [],
    import_jobs::AbstractVector = [],
    simulation_runs::AbstractVector = [],
    demand_scenarios::AbstractVector = [],
    allocation_recommendations::AbstractVector = [],
    recommendation_decisions::AbstractVector = [],
)::MemoryTenantAdminStore
    return MemoryTenantAdminStore(
        _record_map(tenants),
        _record_map(users),
        _record_map(warehouses),
        _record_map(skus),
        _record_map(inventory_positions),
        _record_map(demand_history),
        _record_map(transfer_lanes),
        _record_map(allocation_policies),
        _record_map(import_jobs),
        _record_map(simulation_runs),
        _record_map(demand_scenarios),
        _record_map(allocation_recommendations),
        _record_map(recommendation_decisions),
        Dict{Tuple{UUID,String},UUID}(),
    )
end
