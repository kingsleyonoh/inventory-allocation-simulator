
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
    )
end
