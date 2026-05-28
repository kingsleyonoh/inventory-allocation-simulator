function _count_pending_recommendations(store::MemoryTenantAdminStore, tenant_id::UUID)::Int
    return count(row -> row[:tenant_id] == tenant_id && row[:status] == "proposed", values(store.allocation_recommendations))
end

function _count_pending_recommendations(store::SqlTenantAdminStore, tenant_id::UUID)::Int
    result = LibPQ.execute(store.connection, "SELECT count(*) FROM allocation_recommendations WHERE tenant_id = \$1 AND status = 'proposed'", [string(tenant_id)])
    return Int(first(first(result)))
end

function _unread_local_alert_count(store::MemoryTenantAdminStore, tenant_id::UUID)::Int
    return count(row -> row[:tenant_id] == tenant_id && row[:read_at] === nothing, values(store.local_notifications))
end

function _unread_local_alert_count(store::SqlTenantAdminStore, tenant_id::UUID)::Int
    result = LibPQ.execute(store.connection, "SELECT count(*) FROM local_notifications WHERE tenant_id = \$1 AND read_at IS NULL", [string(tenant_id)])
    return Int(first(first(result)))
end

function _stockout_risk(store::AbstractTenantAdminStore, ctx::TenantContext)::NamedTuple
    inventory = list_inventory_positions(store, ctx; params = Dict("limit" => "250")).inventory
    risky = [row for row in inventory if row.available_units < row.safety_stock_units]
    return (risky = length(risky), total = length(inventory))
end

function render_dashboard_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    risk = _stockout_risk(store, ctx)
    pending = _count_pending_recommendations(store, ctx.tenant_id)
    alerts = _unread_local_alert_count(store, ctx.tenant_id)
    runs = list_simulation_runs(store, ctx; params = Dict("limit" => "5")).simulation_runs
    run_rows = isempty(runs) ? "<tr><td colspan=\"3\">No simulation runs yet. Start a run after importing planning data.</td></tr>" : _join_html([
        "<tr><td>$(_h(run.name))</td><td>$(_h(run.status))</td><td>$(_h(run.scenario_count)) scenarios</td></tr>" for run in runs
    ])
    body = """
<h1>Dashboard</h1>
<p class=\"ias-muted\">Stockout risk, pending allocation decisions, recent simulation runs, and local alerts for this tenant.</p>
<section class=\"ias-grid\" aria-label=\"Dashboard summary\">
  <article class=\"ias-panel\"><h2>Stockout risk</h2><p><strong>$(risk.risky) risky position$(risk.risky == 1 ? "" : "s")</strong></p><p class=\"ias-muted\">$(risk.total) inventory positions checked against safety stock.</p></article>
  <article class=\"ias-panel\"><h2>Pending recommendations</h2><p><strong>$pending pending</strong></p><p class=\"ias-muted\">Planner/admin review queue.</p></article>
  <article class=\"ias-panel\"><h2>Recent runs</h2><p><strong>$(length(runs)) shown</strong></p><p class=\"ias-muted\">Latest queued, running, completed, failed, or cancelled runs.</p></article>
  <article class=\"ias-panel\"><h2>Local alerts</h2><p><a class=\"ias-bell\" aria-label=\"Open $alerts unread notifications\" href=\"/notifications\">Notification bell · $alerts unread</a></p><p class=\"ias-muted\">In-app notifications stay local when external Hub is disabled.</p></article>
</section>
<section class=\"ias-table-wrap\"><table><caption>Recent simulation runs</caption><thead><tr><th scope=\"col\">Run</th><th scope=\"col\">Status</th><th scope=\"col\">Scenarios</th></tr></thead><tbody>$run_rows</tbody></table></section>
"""
    return _app_shell("Dashboard", body; active = "Dashboard")
end

function _fetch_import_jobs(store::MemoryTenantAdminStore, tenant_id::UUID)
    rows = [row for row in values(store.import_jobs) if row[:tenant_id] == tenant_id]
    return sort(rows; by = row -> string(row[:id]))
end

function _fetch_import_jobs(store::SqlTenantAdminStore, tenant_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
        FROM import_jobs WHERE tenant_id = \$1 ORDER BY updated_at DESC LIMIT 25
    """, [string(tenant_id)])
    return [_sql_import_job_row(row) for row in result]
end

function _import_error_lines(errors)::String
    isempty(errors) && return "<span class=\"ias-muted\">No validation errors</span>"
    return "<ul>" * _join_html(["<li>row $(_h(err.row)) · $(_h(err.field)) · $(_h(err.code)) · $(_h(err.message))</li>" for err in errors]) * "</ul>"
end

function render_import_center_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    can_write = _can_write_planning(ctx)
    jobs = [_import_job_response(row) for row in _fetch_import_jobs(store, ctx.tenant_id)]
    rows = isempty(jobs) ? "<tr><td colspan=\"5\">No imports yet. Upload warehouses, SKUs, inventory, demand, or lanes CSV files.</td></tr>" : _join_html([
        "<tr><td>$(_h(job.original_filename))</td><td>$(_h(job.import_type))</td><td>$(_h(job.status))</td><td>$(_h(job.row_count)) rows<br>$(_import_error_lines(job.error_report))</td><td><a class=\"ias-button ias-secondary\" href=\"/imports?retry=$(_h(job.id))\">Retry upload</a></td></tr>" for job in jobs
    ])
    disabled = can_write ? "" : "disabled aria-disabled=\"true\""
    warning = can_write ? "" : "<div class=\"ias-alert\" role=\"alert\">Permission required to upload planning CSV files.</div>"
    body = """
<h1>Import Center</h1>
<p class=\"ias-muted\">Upload CSV planning data, inspect validation errors, and retry corrected files. Bulk CSV workflows are desktop-recommended.</p>
$warning
<section class=\"ias-panel\"><h2>Upload CSV</h2><form method=\"post\" action=\"/imports\" enctype=\"multipart/form-data\"><label for=\"import_type\">Import type</label><select id=\"import_type\" name=\"import_type\"><option>warehouses</option><option>skus</option><option>inventory</option><option>demand</option><option>lanes</option></select><label for=\"file\">CSV file</label><input id=\"file\" name=\"file\" type=\"file\" accept=\".csv,text/csv\"><button type=\"submit\" $disabled>Upload CSV</button></form></section>
<section class=\"ias-panel\"><h2>CSV guidance</h2><p><code>warehouse_code,sku_code,on_hand_units</code> is required for inventory. Warehouses require <code>code,name,region,capacity_units</code>; SKUs require <code>sku_code,name,category</code>.</p></section>
<section class=\"ias-table-wrap\"><table><caption>Upload status and validation errors</caption><thead><tr><th>File</th><th>Type</th><th>Status</th><th>Validation</th><th>Retry</th></tr></thead><tbody>$rows</tbody></table></section>
"""
    return _app_shell("Import Center", body; active = "Imports")
end

function _warehouse_rows(warehouses, can_write::Bool)::String
    isempty(warehouses) && return "<tr><td colspan=\"7\">No warehouses yet.</td></tr>"
    return _join_html([begin
        actions = if can_write
            "<form class=\"ias-inline-form\" method=\"post\" action=\"/warehouses/$(_h(w.id))\"><label>Name<input name=\"name\" value=\"$(_h(w.name))\" required></label><label>Region<input name=\"region\" value=\"$(_h(w.region))\" required></label><label>Capacity units<input name=\"capacity_units\" type=\"number\" min=\"0\" step=\"0.01\" value=\"$(_h(w.capacity_units))\" required></label><label>Handling cost cents<input name=\"handling_cost_cents\" type=\"number\" min=\"0\" step=\"1\" value=\"$(_h(w.handling_cost_cents))\"></label><button class=\"ias-secondary\" type=\"submit\">Edit $(_h(w.code))</button></form><form class=\"ias-inline-form\" method=\"post\" action=\"/warehouses/$(_h(w.id))\"><input type=\"hidden\" name=\"active\" value=\"false\"><button class=\"ias-danger\" type=\"submit\">Deactivate $(_h(w.code))</button></form>"
        else
            "<span class=\"ias-muted\">Read only</span>"
        end
        "<tr><td>$(_h(w.code))</td><td>$(_h(w.name))</td><td>$(_h(w.region))</td><td>$(_h(w.capacity_units))</td><td>$(_h(w.handling_cost_cents))¢</td><td aria-label=\"Warehouse active state for $(_h(w.code))\">$(_status_badge(w.active))</td><td>$actions</td></tr>"
    end for w in warehouses])
end

function render_warehouses_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    can_write = _can_write_planning(ctx)
    warehouses = list_warehouses(store, ctx; params = Dict("limit" => "250")).warehouses
    warning = can_write ? "" : "<div class=\"ias-alert\" role=\"alert\">Permission required to change warehouses.</div>"
    disabled = can_write ? "" : "disabled aria-disabled=\"true\""
    body = """
<h1>Warehouse management</h1>
<p class=\"ias-muted\">Create, edit, and deactivate tenant locations with capacity, region, and handling-cost controls.</p>
$warning
<section class=\"ias-panel\"><h2>Create warehouse</h2><form method=\"post\" action=\"/warehouses\"><label>Code<input name=\"code\" required></label><label>Name<input name=\"name\" required></label><label>Region<input name=\"region\" required></label><label>Capacity units<input name=\"capacity_units\" type=\"number\" min=\"0\" step=\"0.01\" required></label><label>Handling cost cents<input name=\"handling_cost_cents\" type=\"number\" min=\"0\" step=\"1\"></label><button type=\"submit\" $disabled>Create warehouse</button></form></section>
<section class=\"ias-table-wrap\"><table><caption>Warehouses</caption><thead><tr><th>Code</th><th>Name</th><th>Region</th><th>Capacity</th><th>Handling</th><th>State</th><th>Actions</th></tr></thead><tbody>$(_warehouse_rows(warehouses, can_write))</tbody></table></section>
"""
    return _app_shell("Warehouse management", body; active = "Warehouses")
end

function _sku_rows(skus, can_write::Bool)::String
    isempty(skus) && return "<tr><td colspan=\"8\">No SKUs yet.</td></tr>"
    return _join_html([begin
        actions = if can_write
            "<form class=\"ias-inline-form\" method=\"post\" action=\"/skus/$(_h(s.id))\"><label>Name<input name=\"name\" value=\"$(_h(s.name))\" required></label><label>Category<input name=\"category\" value=\"$(_h(s.category))\" required></label><label>Unit volume<input name=\"unit_volume\" type=\"number\" min=\"0.0001\" step=\"0.0001\" value=\"$(_h(s.unit_volume))\"></label><label>Unit margin cents<input name=\"unit_margin_cents\" type=\"number\" min=\"0\" value=\"$(_h(s.unit_margin_cents))\"></label><label>Stockout cost cents<input name=\"stockout_cost_cents\" type=\"number\" min=\"0\" value=\"$(_h(s.stockout_cost_cents))\"></label><label>Holding cost cents<input name=\"holding_cost_cents\" type=\"number\" min=\"0\" value=\"$(_h(s.holding_cost_cents))\"></label><button class=\"ias-secondary\" type=\"submit\">Edit $(_h(s.sku_code))</button></form><form class=\"ias-inline-form\" method=\"post\" action=\"/skus/$(_h(s.id))\"><input type=\"hidden\" name=\"active\" value=\"false\"><button class=\"ias-danger\" type=\"submit\">Deactivate $(_h(s.sku_code))</button></form>"
        else
            "<span class=\"ias-muted\">Read only</span>"
        end
        "<tr><td>$(_h(s.sku_code))</td><td>$(_h(s.name))</td><td>$(_h(s.category))</td><td>$(_h(s.unit_volume))</td><td>$(_h(s.unit_margin_cents))¢</td><td>$(_h(s.stockout_cost_cents))¢ / $(_h(s.holding_cost_cents))¢</td><td>$(_status_badge(s.active))</td><td>$actions</td></tr>"
    end for s in skus])
end

function render_skus_page(store::AbstractTenantAdminStore, ctx::TenantContext)::String
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    can_write = _can_write_planning(ctx)
    skus = list_skus(store, ctx; params = Dict("limit" => "250")).skus
    warning = can_write ? "" : "<div class=\"ias-alert\" role=\"alert\">Permission required to change SKUs.</div>"
    disabled = can_write ? "" : "disabled aria-disabled=\"true\""
    body = """
<h1>SKU management</h1>
<p class=\"ias-muted\">Manage categories, unit volume, margin, stockout cost, holding cost, and active-state controls.</p>
$warning
<section class=\"ias-panel\"><h2>Create SKU</h2><form method=\"post\" action=\"/skus\"><label>SKU code<input name=\"sku_code\" required></label><label>Name<input name=\"name\" required></label><label>Category<input name=\"category\" required></label><label>Unit volume<input name=\"unit_volume\" type=\"number\" min=\"0.0001\" step=\"0.0001\"></label><label>Unit margin cents<input name=\"unit_margin_cents\" type=\"number\" min=\"0\"></label><label>Stockout cost cents<input name=\"stockout_cost_cents\" type=\"number\" min=\"0\"></label><label>Holding cost cents<input name=\"holding_cost_cents\" type=\"number\" min=\"0\"></label><button type=\"submit\" $disabled>Create SKU</button></form></section>
<section class=\"ias-table-wrap\"><table><caption>SKUs</caption><thead><tr><th>Code</th><th>Name</th><th>Category</th><th>Volume</th><th>Margin</th><th>Stockout / holding</th><th>State</th><th>Actions</th></tr></thead><tbody>$(_sku_rows(skus, can_write))</tbody></table></section>
"""
    return _app_shell("SKU management", body; active = "SKUs")
end

