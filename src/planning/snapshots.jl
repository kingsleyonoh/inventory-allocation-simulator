using UUIDs

const SNAPSHOT_MAX_ROWS = 1_000_000

function _snapshot_page()::CursorPageRequest
    return CursorPageRequest(SNAPSHOT_MAX_ROWS, nothing, Dict{String,String}())
end

function _snapshot_policy(store::AbstractTenantAdminStore, ctx::TenantContext, policy_id::UUID)
    policies = [_policy_response(row) for row in fetch_allocation_policies(store, ctx.tenant_id, _snapshot_page())]
    match = findfirst(policy -> policy.id == string(policy_id), policies)
    match === nothing && throw(ApiError("NOT_FOUND", "Allocation policy not found"; status = 404))
    return policies[match]
end

function capture_simulation_input_snapshot(
    store::AbstractTenantAdminStore,
    ctx::TenantContext,
    policy_id,
)::NamedTuple
    authorize!(ctx, "run_cancel", "simulation")
    parsed_policy_id = _uuid_value(policy_id)
    policy = _snapshot_policy(store, ctx, parsed_policy_id)
    return (
        tenant_id = string(ctx.tenant_id),
        policy = policy,
        warehouses = [_warehouse_response(row) for row in fetch_warehouses(store, ctx.tenant_id, _snapshot_page())],
        skus = [_sku_response(row) for row in fetch_skus(store, ctx.tenant_id, _snapshot_page())],
        inventory_positions = [_inventory_response(row) for row in fetch_inventory_positions(store, ctx.tenant_id, _snapshot_page())],
        demand_history = [_demand_response(row) for row in fetch_demand_history(store, ctx.tenant_id, _snapshot_page())],
        transfer_lanes = [_lane_response(row) for row in fetch_transfer_lanes(store, ctx.tenant_id, _snapshot_page())],
    )
end
