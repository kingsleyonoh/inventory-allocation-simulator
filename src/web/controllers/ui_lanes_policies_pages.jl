function _uuid_name_map(items, id_field::Symbol, name_field::Symbol)::Dict{String,String}
    return Dict(string(getproperty(item, id_field)) => String(getproperty(item, name_field)) for item in items)
end

function _warehouse_option_rows(warehouses)::String
    return _join_html(["<option value=\"$(_h(w.id))\">$(_h(w.code)) · $(_h(w.name))</option>" for w in warehouses])
end

function _lane_rows(lanes, warehouses, can_write::Bool)::String
    isempty(lanes) && return "<tr><td colspan=\"6\">No transfer lanes yet.</td></tr>"
    wh_names = Dict(w.id => string(w.code, " · ", w.name) for w in warehouses)
    return _join_html([begin
        from_label = get(wh_names, lane.from_warehouse_id, lane.from_warehouse_id)
        to_label = get(wh_names, lane.to_warehouse_id, lane.to_warehouse_id)
        capacity = lane.capacity_units_day === nothing ? "Uncapped" : string(lane.capacity_units_day, " units/day")
        capacity_value = lane.capacity_units_day === nothing ? "" : string(lane.capacity_units_day)
        controls = can_write ? "<form class=\"ias-inline-form\" method=\"post\" action=\"/lanes/$(_h(lane.id))\"><label>Lead time days<input name=\"lead_time_days\" type=\"number\" min=\"0\" step=\"1\" value=\"$(_h(lane.lead_time_days))\" required></label><label>Cost per unit cents<input name=\"cost_per_unit_cents\" type=\"number\" min=\"0\" step=\"1\" value=\"$(_h(lane.cost_per_unit_cents))\" required></label><label>Capacity units/day<input name=\"capacity_units_day\" type=\"number\" min=\"0\" step=\"0.01\" value=\"$(_h(capacity_value))\"></label><label>Active state<select name=\"active\"><option value=\"true\">Active</option><option value=\"false\">Inactive</option></select></label><button class=\"ias-secondary\" type=\"submit\">Update lane</button></form><form class=\"ias-inline-form\" method=\"post\" action=\"/lanes/$(_h(lane.id))\"><input type=\"hidden\" name=\"active\" value=\"false\"><button class=\"ias-danger\" type=\"submit\">Deactivate lane</button></form>" : "<span class=\"ias-muted\">Read only</span>"
        "<tr><td>$(_h(from_label)) → $(_h(to_label))</td><td>$(_h(lane.lead_time_days)) days</td><td>$(_h(lane.cost_per_unit_cents))¢</td><td>$(_h(capacity))</td><td>$(_status_badge(lane.active))</td><td>$controls</td></tr>"
    end for lane in lanes])
end

function _apply_lane_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload; lane_id = nothing)::NamedTuple
    return lane_id === nothing ? create_transfer_lane!(store, ctx, payload) : update_transfer_lane!(store, ctx, lane_id, payload)
end

function render_transfer_lanes_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    can_write = _can_write_planning(ctx)
    warehouses = list_warehouses(store, ctx; params = Dict("limit" => "250")).warehouses
    lanes = list_transfer_lanes(store, ctx; params = Dict("limit" => "250")).lanes
    disabled = can_write ? "" : "disabled aria-disabled=\"true\""
    warning = can_write ? "" : "<div class=\"ias-alert\" role=\"alert\">Permission required to change transfer lanes.</div>"
    options = _warehouse_option_rows(warehouses)
    body = """
<h1>Transfer lane management</h1>
<p class=\"ias-muted\">Control lead time, transfer cost, daily capacity, and active-state for tenant-scoped lanes.</p>
$warning
<section class=\"ias-panel\"><h2>Create transfer lane</h2><form method=\"post\" action=\"/lanes\"><label>From warehouse<select name=\"from_warehouse_id\" required>$options</select></label><label>To warehouse<select name=\"to_warehouse_id\" required>$options</select></label><label>Lead time days<input name=\"lead_time_days\" type=\"number\" min=\"0\" step=\"1\" required></label><label>Cost per unit cents<input name=\"cost_per_unit_cents\" type=\"number\" min=\"0\" step=\"1\" required></label><label>Capacity units/day<input name=\"capacity_units_day\" type=\"number\" min=\"0\" step=\"0.01\"></label><label>Active state<select name=\"active\"><option value=\"true\">Active</option><option value=\"false\">Inactive</option></select></label><button type=\"submit\" $disabled>Create lane</button></form></section>
<section class=\"ias-table-wrap\"><table><caption>Transfer lanes</caption><thead><tr><th>Lane</th><th>Lead time</th><th>Cost/unit</th><th>Capacity</th><th>State</th><th>Controls</th></tr></thead><tbody>$(_lane_rows(lanes, warehouses, can_write))</tbody></table></section>
"""
    return _app_shell("Transfer lane management", body; active = "Lanes")
end

function _apply_policy_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload; policy_id = nothing)::NamedTuple
    normalized = Dict{String,Any}()
    for key in ["name", "objective", "planning_horizon_days", "service_level_target", "max_transfer_cost_cents", "allow_cross_region", "status"]
        value = _payload_get(payload, key, nothing)
        value === nothing && continue
        key == "max_transfer_cost_cents" && isempty(strip(String(value))) && continue
        normalized[key] = value
    end
    return policy_id === nothing ? create_allocation_policy!(store, ctx, normalized) : update_allocation_policy!(store, ctx, policy_id, normalized)
end

function _policy_rows(policies, can_manage::Bool)::String
    isempty(policies) && return "<tr><td colspan=\"8\">No allocation policies yet.</td></tr>"
    return _join_html([begin
        max_cost = p.max_transfer_cost_cents === nothing ? "No cap" : string(p.max_transfer_cost_cents, "¢")
        max_cost_value = p.max_transfer_cost_cents === nothing ? "" : string(p.max_transfer_cost_cents)
        cross_region = p.allow_cross_region ? "Allowed" : "Blocked"
        controls = can_manage ? "<form class=\"ias-inline-form\" method=\"post\" action=\"/policies/$(_h(p.id))\"><label>Name<input name=\"name\" value=\"$(_h(p.name))\" required></label><label>Objective<input name=\"objective\" value=\"$(_h(p.objective))\" required></label><label>Planning horizon days<input name=\"planning_horizon_days\" type=\"number\" min=\"1\" max=\"180\" value=\"$(_h(p.planning_horizon_days))\" required></label><label>Service-level target<input name=\"service_level_target\" type=\"number\" min=\"0.01\" max=\"1\" step=\"0.01\" value=\"$(_h(p.service_level_target))\" required></label><label>Max transfer cost cents<input name=\"max_transfer_cost_cents\" type=\"number\" min=\"0\" step=\"1\" value=\"$(_h(max_cost_value))\"></label><label>Allow cross-region<select name=\"allow_cross_region\"><option value=\"true\">Allowed</option><option value=\"false\">Blocked</option></select></label><label>Status<select name=\"status\"><option value=\"draft\">Draft</option><option value=\"active\">Active</option><option value=\"archived\">Archived</option></select></label><button class=\"ias-secondary\" type=\"submit\">Update policy</button></form><form class=\"ias-inline-form\" method=\"post\" action=\"/policies/$(_h(p.id))\"><input type=\"hidden\" name=\"status\" value=\"archived\"><button class=\"ias-danger\" type=\"submit\">Archive policy</button></form>" : "<span class=\"ias-muted\">Read only</span>"
        "<tr><td>$(_h(p.name))</td><td>$(_h(p.objective))</td><td>$(_h(p.planning_horizon_days)) days</td><td>$(_h(p.service_level_target))</td><td>$(_h(max_cost))</td><td>$(_h(cross_region))</td><td>$(_h(p.status))</td><td>$controls</td></tr>"
    end for p in policies])
end

function render_allocation_policies_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    can_manage = try
        authorize!(ctx, "manage", "policy")
        true
    catch err
        err isa AuthzError || rethrow(err)
        false
    end
    policies = list_allocation_policies(store, ctx; params = Dict("limit" => "250")).policies
    disabled = can_manage ? "" : "disabled aria-disabled=\"true\""
    warning = can_manage ? "" : "<div class=\"ias-alert\" role=\"alert\">Admin permission required to create allocation policies.</div>"
    objective_options = _join_html(["<option value=\"$(_h(item))\">$(_h(item))</option>" for item in sort(collect(POLICY_OBJECTIVES))])
    body = """
<h1>Allocation policy</h1>
<p class=\"ias-muted\">Set solver objective, planning horizon, service-level target, and transfer constraints.</p>
$warning
<section class=\"ias-panel\"><h2>Create allocation policy</h2><form method=\"post\" action=\"/policies\"><label>Name<input name=\"name\" required></label><label>Objective<select name=\"objective\" required>$objective_options</select></label><label>Planning horizon days<input name=\"planning_horizon_days\" type=\"number\" min=\"1\" max=\"180\" required></label><label>Service-level target<input name=\"service_level_target\" type=\"number\" min=\"0.01\" max=\"1\" step=\"0.01\" required></label><label>Max transfer cost cents<input name=\"max_transfer_cost_cents\" type=\"number\" min=\"0\" step=\"1\"></label><label>Allow cross-region<select name=\"allow_cross_region\"><option value=\"true\">Allowed</option><option value=\"false\">Blocked</option></select></label><label>Status<select name=\"status\"><option value=\"draft\">Draft</option><option value=\"active\">Active</option><option value=\"archived\">Archived</option></select></label><button type=\"submit\" $disabled>Create policy</button></form></section>
<section class=\"ias-table-wrap\"><table><caption>Allocation policies</caption><thead><tr><th>Name</th><th>Objective</th><th>Horizon</th><th>Service level</th><th>Cost cap</th><th>Region constraint</th><th>Status</th><th>Controls</th></tr></thead><tbody>$(_policy_rows(policies, can_manage))</tbody></table></section>
"""
    return _app_shell("Allocation policy", body; active = "Policies")
end

