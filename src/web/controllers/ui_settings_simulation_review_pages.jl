function _contact_from_payload(current, payload)
    contact = Dict{String,Any}(String(k) => v for (k, v) in pairs(current.contact))
    email = _optional_text(payload, "contact_email")
    email !== nothing && (contact["email"] = email)
    return contact
end

function _apply_tenant_settings_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    current = get_tenant_profile(store, ctx)
    body = Dict{String,Any}(
        "name" => _payload_get(payload, "name", current.name),
        "legal_name" => _payload_get(payload, "legal_name", current.legal_name),
        "full_legal_name" => _payload_get(payload, "full_legal_name", current.full_legal_name),
        "display_name" => _payload_get(payload, "display_name", current.display_name),
        "contact" => _contact_from_payload(current, payload),
        "address" => current.address,
        "registration" => current.registration,
    )
    return update_tenant_settings!(store, ctx, body)
end

function _apply_user_create_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload)::NamedTuple
    return create_user!(store, ctx, payload)
end

function _apply_user_update_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, user_id, payload)::NamedTuple
    return update_user!(store, ctx, user_id, payload)
end

function _tenant_user_rows(users, can_manage::Bool)::String
    isempty(users) && return "<tr><td colspan=\"5\">No users configured.</td></tr>"
    return _join_html([begin
        state = u.is_active ? "Active" : "Inactive"
        controls = can_manage ? "<form class=\"ias-inline-form\" method=\"post\" action=\"/settings/users/$(_h(u.id))\"><label>Role<select name=\"role\"><option value=\"admin\">Admin</option><option value=\"planner\">Planner</option><option value=\"viewer\">Viewer</option></select></label><label>Active<select name=\"is_active\"><option value=\"true\">Active</option><option value=\"false\">Inactive</option></select></label><button class=\"ias-secondary\" type=\"submit\">Update user</button></form>" : "<span class=\"ias-muted\">Read only</span>"
        "<tr><td>$(_h(u.email))</td><td>$(_h(u.name))</td><td>$(_h(u.role))</td><td>$(_h(state))</td><td>$controls</td></tr>"
    end for u in users])
end

function render_tenant_settings_page(store::AbstractTenantAdminStore, config::AppConfig, ctx::TenantContext)::String
    profile = get_tenant_profile(store, ctx)
    users = list_users(store, ctx)
    can_manage = true
    contact_email = haskey(profile.contact, "email") ? profile.contact["email"] : ""
    body = """
<h1>Tenant settings</h1>
<p class=\"ias-muted\">Manage tenant profile, active users, and one-time API-key rotation. Raw API keys are never displayed after creation.</p>
<section class=\"ias-panel\"><h2>Profile</h2><form method=\"post\" action=\"/settings\"><label>Tenant name<input name=\"name\" value=\"$(_h(profile.name))\" required></label><label>Legal name<input name=\"legal_name\" value=\"$(_h(profile.legal_name))\" required></label><label>Full legal name<input name=\"full_legal_name\" value=\"$(_h(profile.full_legal_name))\" required></label><label>Display name<input name=\"display_name\" value=\"$(_h(profile.display_name))\" required></label><label>Contact email<input name=\"contact_email\" type=\"email\" value=\"$(_h(contact_email))\"></label><button type=\"submit\">Save profile</button></form></section>
<section class=\"ias-panel\"><h2>Create user</h2><form method=\"post\" action=\"/settings/users\"><label>Email<input name=\"email\" type=\"email\" required></label><label>Name<input name=\"name\" required></label><label>Role<select name=\"role\"><option value=\"admin\">Admin</option><option value=\"planner\">Planner</option><option value=\"viewer\">Viewer</option></select></label><label>Active<select name=\"is_active\"><option value=\"true\">Active</option><option value=\"false\">Inactive</option></select></label><button type=\"submit\">Create user</button></form></section>
<section class=\"ias-panel\"><h2>API key management</h2><p class=\"ias-muted\">Rotation returns a one-time raw key in the API response; this server-rendered console redirects back without storing or showing it.</p><form method=\"post\" action=\"/settings/api-key/rotate\"><button class=\"ias-danger\" type=\"submit\">Rotate API key</button></form></section>
<section class=\"ias-table-wrap\"><table><caption>Tenant users</caption><thead><tr><th>Email</th><th>Name</th><th>Role</th><th>State</th><th>Controls</th></tr></thead><tbody>$(_tenant_user_rows(users, can_manage))</tbody></table></section>
"""
    return _app_shell("Tenant settings", body; active = "Settings")
end

function _simulation_rows(runs)::String
    isempty(runs) && return "<tr><td colspan=\"6\">No simulation runs yet.</td></tr>"
    return _join_html([begin
        diagnostics = r.status == "failed" ? _h(something(r.error_message, "failed")) : "View diagnostics"
        "<tr><td>$(_h(r.name))</td><td>$(_h(r.status))</td><td>$(_h(r.scenario_count))</td><td>$(_h(something(r.started_at, "not started")))</td><td>$(_h(diagnostics))</td><td><a class=\"ias-button ias-secondary\" href=\"/simulations/$(_h(r.id))\">View diagnostics</a></td></tr>"
    end for r in runs])
end

function render_simulations_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    can_run = try
        authorize!(ctx, "run_cancel", "simulation")
        true
    catch err
        err isa AuthzError || rethrow(err)
        false
    end
    policies = list_allocation_policies(store, ctx; params = Dict("limit" => "250", "status" => "active")).policies
    runs = list_simulation_runs(store, ctx; params = Dict("limit" => "250")).simulation_runs
    options = _join_html(["<option value=\"$(_h(p.id))\">$(_h(p.name))</option>" for p in policies])
    disabled = can_run ? "" : "disabled aria-disabled=\"true\""
    body = """
<h1>Simulation runs</h1>
<p class=\"ias-muted\">Start scenario runs, review lifecycle status, and open frozen run diagnostics.</p>
<section class=\"ias-panel\"><h2>Run simulation</h2><form method=\"post\" action=\"/simulations\"><label>Name<input name=\"name\" required></label><label>Policy<select name=\"policy_id\" required>$options</select></label><label>Scenario count<input name=\"scenario_count\" type=\"number\" min=\"1\" max=\"100\" value=\"10\"></label><button type=\"submit\" $disabled>Start simulation</button></form></section>
<section class=\"ias-table-wrap\"><table><caption>Simulation run list</caption><thead><tr><th>Name</th><th>Status</th><th>Scenarios</th><th>Started</th><th>Solver diagnostics</th><th>Detail</th></tr></thead><tbody>$(_simulation_rows(runs))</tbody></table></section>
"""
    return _app_shell("Simulation runs", body; active = "Simulations")
end

function _first_demands(scenarios)::String
    isempty(scenarios) && return "<tr><td colspan=\"4\">No scenarios stored yet.</td></tr>"
    rows = String[]
    for scenario in scenarios
        demands = get(scenario.demand_payload, "demands", [])
        first_demand = isempty(demands) ? Dict{String,Any}() : first(demands)
        baseline = get(first_demand, "baseline_units", "n/a")
        uncertainty = get(first_demand, "uncertainty_units", "n/a")
        push!(rows, "<tr><td>$(_h(scenario.scenario_index))</td><td>$(_h(scenario.probability_weight))</td><td>$(_h(baseline))</td><td>$(_h(uncertainty))</td></tr>")
    end
    return _join_html(rows)
end

function _run_recommendation_rows(store::AbstractTenantAdminStore, ctx::TenantContext, run_id)::String
    recs = [recommendation_view_model(row) for row in fetch_allocation_recommendations(store, ctx.tenant_id, UUID(String(run_id)))]
    isempty(recs) && return "<tr><td colspan=\"5\">No recommendations persisted for this run.</td></tr>"
    return _join_html([begin
        constraints = join(get(rec.explanation, "binding_constraints", []), ", ")
        sensitivity = JSON3.write(get(rec.explanation, "scenario_sensitivity", Dict{String,Any}()))
        "<tr><td>$(_h(rec.net_value_cents))¢</td><td>$(_h(rec.confidence_score))</td><td>$(_h(rec.status))</td><td>$(_h(constraints))<br><strong>Scenario sensitivity</strong>: $(_h(sensitivity))</td><td><a class=\"ias-button ias-secondary\" href=\"/recommendations/$(_h(rec.id))\">Open recommendation</a></td></tr>"
    end for rec in recs])
end

function render_simulation_detail_page(store::AbstractTenantAdminStore, ctx::TenantContext, run_id)::String
    run = get_simulation_run(store, ctx, run_id)
    policy_name = hasproperty(run.input_snapshot, :policy) ? run.input_snapshot.policy.name : "Frozen policy"
    error_text = something(run.error_message, "None")
    body = """
<h1>Simulation detail</h1>
<p class=\"ias-muted\">Frozen scenario summaries and solver diagnostics for $(_h(run.name)); completed runs never reread mutable planning data.</p>
<section class=\"ias-grid\" aria-label=\"Run summary\"><article class=\"ias-panel\"><h2>Status</h2><p>$(_h(run.status))</p></article><article class=\"ias-panel\"><h2>Policy snapshot</h2><p>$(_h(policy_name))</p></article><article class=\"ias-panel\"><h2>Scenarios</h2><p>$(_h(run.scenario_count)) planned</p></article><article class=\"ias-panel\"><h2>Error</h2><p>$(_h(error_text))</p></article></section>
<section class=\"ias-table-wrap\"><table><caption>Scenario summaries</caption><thead><tr><th>Index</th><th>Weight</th><th>Baseline units</th><th>Uncertainty</th></tr></thead><tbody>$(_first_demands(run.scenarios))</tbody></table></section>
<section class=\"ias-table-wrap\"><table><caption>Solver diagnostics and recommendations</caption><thead><tr><th>Net value</th><th>Confidence</th><th>Status</th><th>Binding constraints</th><th>Detail</th></tr></thead><tbody>$(_run_recommendation_rows(store, ctx, run.id))</tbody></table></section>
"""
    return _app_shell("Simulation detail", body; active = "Simulations")
end

function _fetch_recommendation(store::MemoryTenantAdminStore, tenant_id::UUID, recommendation_id::UUID)
    row = get(store.allocation_recommendations, recommendation_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function _fetch_recommendation(store::SqlTenantAdminStore, tenant_id::UUID, recommendation_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status, created_at, updated_at
        FROM allocation_recommendations WHERE tenant_id = \$1 AND id = \$2 LIMIT 1
    """, [string(tenant_id), string(recommendation_id)])
    isempty(result) && return nothing
    return _sql_recommendation_row(first(result))
end

function render_recommendation_detail_page(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = _fetch_recommendation(store, ctx.tenant_id, UUID(String(recommendation_id)))
    row === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    rec = recommendation_view_model(row)
    explanation = rec.explanation
    constraints = join(get(explanation, "binding_constraints", []), ", ")
    sensitivity = JSON3.write(get(explanation, "scenario_sensitivity", Dict{String,Any}()))
    tradeoffs = join(get(explanation, "accepted_tradeoffs", []), ", ")
    body = """
<h1>Recommendation detail</h1>
<p class=\"ias-muted\">Explain the transfer, constraints, demand-scenario sensitivity, and available review actions.</p>
<section class=\"ias-grid\" aria-label=\"Recommendation summary\"><article class=\"ias-panel\"><h2>Net value</h2><p>$(_h(rec.net_value_cents))¢</p></article><article class=\"ias-panel\"><h2>Confidence</h2><p>$(_h(rec.confidence_score))</p></article><article class=\"ias-panel\"><h2>Transfer units</h2><p>$(_h(rec.transfer_units))</p></article><article class=\"ias-panel\"><h2>Status</h2><p>$(_h(rec.status))</p></article></section>
<section class=\"ias-panel\"><h2>Binding constraints</h2><p>$(_h(constraints))</p><h2>Scenario sensitivity</h2><pre>$(_h(sensitivity))</pre><h2>Accepted tradeoffs</h2><p>$(_h(tradeoffs))</p></section>
<section class=\"ias-panel\" aria-label=\"Recommendation actions\"><h2>Actions</h2><div class=\"ias-grid\"><form class=\"ias-inline-form\" method=\"post\" action=\"/api/recommendations/$(_h(rec.id))/approve\"><label>Approval note<input name=\"reason\" value=\"Approved after reviewing constraints\"></label><button type=\"submit\">Approve</button></form><form class=\"ias-inline-form\" method=\"post\" action=\"/api/recommendations/$(_h(rec.id))/reject\"><label>Rejection reason<input name=\"reason\" required placeholder=\"Required reason\"></label><button class=\"ias-danger\" type=\"submit\">Reject</button></form><form class=\"ias-inline-form\" method=\"post\" action=\"/api/recommendations/$(_h(rec.id))/export\"><label>Export note<input name=\"reason\" value=\"Export approved transfer plan\"></label><button class=\"ias-secondary\" type=\"submit\">Export CSV</button></form></div><p class=\"ias-muted\">Approve, reject, and export actions use the tenant-scoped recommendation transition API and write decision audit rows.</p></section>
"""
    return _app_shell("Recommendation detail", body; active = "Simulations")
end

