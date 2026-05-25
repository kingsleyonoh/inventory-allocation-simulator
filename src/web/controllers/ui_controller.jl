using Genie.Requests
using HTTP

const UI_SESSION_COOKIE = "ias_session"
const UI_SESSION_TTL_HOURS = 12

function _h(value)::String
    text = string(value)
    text = replace(text, "&" => "&amp;")
    text = replace(text, "<" => "&lt;")
    text = replace(text, ">" => "&gt;")
    text = replace(text, "\"" => "&quot;")
    return replace(text, "'" => "&#39;")
end

function _next_param(path::AbstractString)::String
    return replace(HTTP.URIs.escapeuri(String(path)), "/" => "%2F")
end

const UI_NEXT_ALLOWLIST = Set(["/dashboard", "/imports", "/warehouses", "/skus", "/lanes", "/policies", "/settings", "/simulations", "/notifications"])

function _safe_ui_next(value)::String
    raw = strip(String(value))
    isempty(raw) && return "/dashboard"
    startswith(raw, "//") && return "/dashboard"
    occursin("://", raw) && return "/dashboard"
    path = startswith(raw, "/") ? raw : string("/", raw)
    path = split(path, "?"; limit = 2)[1]
    path in UI_NEXT_ALLOWLIST || return "/dashboard"
    return path
end

function _join_html(parts)::String
    return join(String.(parts), "\n")
end

function _status_badge(active::Bool)::String
    label = active ? "Active" : "Inactive"
    tone = active ? "success" : "muted"
    return "<span class=\"ias-badge ias-badge-$tone\">$label</span>"
end

function _app_shell(title::AbstractString, body::AbstractString; active::AbstractString = "")::String
    nav = [
        ("Dashboard", "/dashboard"), ("Imports", "/imports"),
        ("Warehouses", "/warehouses"), ("SKUs", "/skus"),
        ("Lanes", "/lanes"), ("Policies", "/policies"),
        ("Simulations", "/simulations"), ("Notifications", "/notifications"), ("Settings", "/settings"),
    ]
    links = _join_html(["<a class=\"ias-nav-link $(active == label ? "is-active" : "")\" href=\"$href\">$label</a>" for (label, href) in nav])
    return """
<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>$(_h(title)) · Inventory Allocation Simulator</title>
  <style>
    :root { color-scheme: light; --ink:#122033; --muted:#5b6472; --line:#d8dee8; --bg:#f7f9fc; --panel:#ffffff; --focus:#1d4ed8; --good:#12633f; --warn:#8a4b00; --bad:#9f1239; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--ink); font-family: "Atkinson Hyperlegible", "Segoe UI", ui-sans-serif, system-ui, sans-serif; line-height:1.45; }
    h1, h2, .ias-brand { font-family: "Aptos Display", Georgia, ui-serif, serif; line-height:1.15; }
    h1 { font-size: clamp(2rem, 3vw, 3rem); margin:0 0 .75rem; }
    h2 { font-size: clamp(1.25rem, 2vw, 1.65rem); }
    a, button, input, select { outline-offset: 3px; }
    a:focus-visible, button:focus-visible, input:focus-visible, select:focus-visible { outline: 3px solid var(--focus); }
    .ias-shell { min-height:100vh; display:grid; grid-template-columns: 220px 1fr; }
    .ias-sidebar { background:#0f1b2d; color:white; padding:1.25rem; }
    .ias-brand { font-size:1rem; font-weight:800; letter-spacing:.03em; margin-bottom:1rem; }
    .ias-nav-link { display:block; color:#dbeafe; text-decoration:none; padding:.65rem .75rem; border-radius:.5rem; margin:.1rem 0; }
    .ias-nav-link.is-active, .ias-nav-link:hover { background:#1e3a5f; color:white; }
    .ias-main { padding:1.5rem; max-width:1280px; width:100%; }
    .ias-panel { background:var(--panel); border:1px solid var(--line); border-radius:.85rem; padding:1rem; box-shadow:0 1px 2px rgba(15, 23, 42, .05); }
    .ias-grid { display:grid; gap:1rem; grid-template-columns: repeat(4, minmax(0, 1fr)); }
    .ias-stack { display:grid; gap:1rem; }
    .ias-table-wrap { overflow-x:auto; border:1px solid var(--line); border-radius:.75rem; background:white; }
    table { width:100%; border-collapse:collapse; min-width:760px; }
    caption { text-align:left; font-weight:700; padding:1rem; }
    th, td { padding:.7rem .85rem; border-top:1px solid var(--line); text-align:left; vertical-align:top; }
    th { color:#334155; background:#f1f5f9; font-size:.88rem; }
    label { display:block; font-weight:700; margin:.5rem 0 .25rem; }
    input, select { width:100%; min-height:2.6rem; border:1px solid #aab4c3; border-radius:.45rem; padding:.55rem .7rem; background:white; color:var(--ink); }
    button, .ias-button { border:1px solid #1d4ed8; background:#1d4ed8; color:white; border-radius:.45rem; padding:.55rem .85rem; font-weight:700; cursor:pointer; text-decoration:none; display:inline-block; }
    button[disabled], .ias-button[aria-disabled=\"true\"] { background:#94a3b8; border-color:#94a3b8; cursor:not-allowed; }
    .ias-secondary { background:white; color:#1d4ed8; }
    .ias-danger { border-color:var(--bad); background:var(--bad); }
    .ias-muted { color:var(--muted); }
    .ias-badge { display:inline-flex; gap:.25rem; align-items:center; border-radius:999px; padding:.2rem .55rem; font-size:.82rem; font-weight:800; border:1px solid currentColor; }
    .ias-badge-success { color:var(--good); background:#ecfdf5; }
    .ias-badge-muted { color:#475569; background:#f8fafc; }
    .ias-badge-warning { color:var(--warn); background:#fff7ed; }
    .ias-alert { border:1px solid #f59e0b; background:#fffbeb; color:#713f12; padding:.75rem; border-radius:.65rem; }
    .ias-bell { display:inline-flex; align-items:center; gap:.35rem; border:1px solid #bfdbfe; background:#eff6ff; color:#1e3a8a; border-radius:999px; padding:.25rem .6rem; font-weight:800; text-decoration:none; }
    .ias-inline-form { display:grid; gap:.45rem; min-width:14rem; }
    .ias-inline-form + .ias-inline-form { margin-top:.6rem; }
    .ias-login { min-height:100vh; display:grid; place-items:center; padding:1rem; }
    .ias-login-card { width:min(100%, 440px); background:white; border:1px solid var(--line); border-radius:1rem; padding:1.25rem; }
    @media (max-width: 800px) { .ias-shell { grid-template-columns:1fr; } .ias-sidebar { position:static; } .ias-main { padding:1rem; } .ias-grid { grid-template-columns:1fr; } table { min-width:700px; } }
    @media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior:auto !important; transition:none !important; } }
  </style>
</head>
<body>
<a class=\"ias-nav-link\" href=\"#content\">Skip to content</a>
<div class=\"ias-shell\">
  <aside class=\"ias-sidebar\" aria-label=\"Operations console navigation\"><div class=\"ias-brand\">IAS Console</div>$links<form method=\"post\" action=\"/logout\"><button class=\"ias-secondary\" type=\"submit\">Sign out</button></form></aside>
  <main id=\"content\" class=\"ias-main\">$body</main>
</div>
</body>
</html>
"""
end

function render_login_page(; error::Union{Nothing,AbstractString} = nothing, next::AbstractString = "/dashboard")::String
    alert = error === nothing ? "" : "<div class=\"ias-alert\" role=\"alert\">$(_h(error))</div>"
    next_value = _h(next)
    return """
<!doctype html>
<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Operations console sign in</title></head>
<body class=\"ias-login\" style=\"font-family:'Atkinson Hyperlegible','Segoe UI',system-ui,sans-serif;background:#f7f9fc;color:#122033;\">
<section class=\"ias-login-card\" aria-labelledby=\"login-title\" style=\"width:min(100%,440px);background:#fff;border:1px solid #d8dee8;border-radius:1rem;padding:1.25rem;\">
<h1 id=\"login-title\">Operations console sign in</h1>
<p id=\"login-guidance\">Use a tenant API key and active user email to create a signed UI session. Raw keys are never stored by the console.</p>
$alert
<form method=\"post\" action=\"/login\" aria-describedby=\"login-guidance\">
<input type=\"hidden\" name=\"next\" value=\"$next_value\">
<label for=\"api_key\">Tenant API key</label><input id=\"api_key\" name=\"api_key\" type=\"password\" autocomplete=\"current-password\" required>
<label for=\"email\">User email</label><input id=\"email\" name=\"email\" type=\"email\" autocomplete=\"email\" required>
<button type=\"submit\">Sign in</button>
</form>
</section></body></html>
"""
end

function render_protected_route_notice(path::AbstractString)::String
    next = _next_param(path)
    return "<main><h1>Authentication required</h1><p>Sign in to continue to this protected operations console route.</p><a href=\"/login?next=$next\">Go to login</a></main>"
end

function _can_write_planning(ctx::TenantContext)::Bool
    try
        authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
        return true
    catch err
        err isa AuthzError || rethrow(err)
        return false
    end
end

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
<section class=\"ias-panel\"><h2>Upload CSV</h2><form method=\"post\" action=\"/api/imports\" enctype=\"multipart/form-data\"><label for=\"import_type\">Import type</label><select id=\"import_type\" name=\"import_type\"><option>warehouses</option><option>skus</option><option>inventory</option><option>demand</option><option>lanes</option></select><label for=\"file\">CSV file</label><input id=\"file\" name=\"file\" type=\"file\" accept=\".csv,text/csv\"><button type=\"submit\" $disabled>Upload CSV</button></form></section>
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

function _html_response(html::AbstractString; status::Int = 200)
    return HTTP.Response(status, ["Content-Type" => "text/html; charset=utf-8"], String(html))
end

function _redirect_response(location::AbstractString; status::Int = 303)
    return HTTP.Response(status, ["Location" => String(location), "Cache-Control" => "no-store"], "")
end

function _form_payload()
    form = try
        Requests.postpayload()
    catch
        Dict{String,Any}()
    end
    isempty(form) || return form
    return _json_body()
end

function _login_payload()
    return _form_payload()
end

function _apply_warehouse_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload; warehouse_id = nothing)::NamedTuple
    return warehouse_id === nothing ? create_warehouse!(store, ctx, payload) : update_warehouse!(store, ctx, warehouse_id, payload)
end

function _apply_sku_ui_form!(store::AbstractTenantAdminStore, ctx::TenantContext, payload; sku_id = nothing)::NamedTuple
    return sku_id === nothing ? create_sku!(store, ctx, payload) : update_sku!(store, ctx, sku_id, payload)
end

function _ui_action_failure_response(title::AbstractString, err)
    message = err isa AuthError || err isa ApiError ? err.message : "The request could not be completed"
    status = err isa AuthError || err isa ApiError ? err.status : 500
    return _html_response("<h1>$(_h(title))</h1><div class=\"ias-alert\" role=\"alert\">$(_h(message))</div>"; status = status)
end

function _find_active_user_by_email(store::MemoryTenantAdminStore, tenant_id::UUID, email::AbstractString)
    target = lowercase(strip(String(email)))
    for user in values(store.users)
        user[:tenant_id] == tenant_id || continue
        lowercase(String(user[:email])) == target && Bool(user[:is_active]) && return user
    end
    return nothing
end

function _find_active_user_by_email(store::SqlTenantAdminStore, tenant_id::UUID, email::AbstractString)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, email, name, role, is_active FROM users
        WHERE tenant_id = \$1 AND lower(email) = lower(\$2) AND is_active = true LIMIT 1
    """, [string(tenant_id), strip(String(email))])
    isempty(result) && return nothing
    row = first(result)
    return Dict{Symbol,Any}(:id => UUID(String(row[1])), :tenant_id => UUID(String(row[2])), :email => row[3], :name => row[4], :role => row[5], :is_active => Bool(row[6]))
end

function _persist_ui_session!(::MemoryTenantAdminStore, session_id::String, tenant_id::UUID, user_id::UUID, expires_at::DateTime)
    return session_id
end

function _persist_ui_session!(store::SqlTenantAdminStore, session_id::String, tenant_id::UUID, user_id::UUID, expires_at::DateTime)
    LibPQ.execute(store.connection, """
        INSERT INTO user_sessions (id, tenant_id, user_id, expires_at)
        VALUES (\$1, \$2, \$3, \$4)
    """, [session_id, string(tenant_id), string(user_id), expires_at])
    return session_id
end

function authenticate_ui_login!(store::AbstractTenantAdminStore, config::AppConfig, payload; now::Function = Dates.now)::NamedTuple
    api_key = _required_text(payload, "api_key")
    email = _required_text(payload, "email")
    auth_record = lookup_tenant_by_api_key_hash(store, hash_api_key(api_key))
    auth_record === nothing && throw(AuthError("UNAUTHORIZED", "Invalid API key"; status = 401))
    auth_record.is_active || throw(AuthError("FORBIDDEN", "Tenant is inactive"; status = 403))
    user = _find_active_user_by_email(store, auth_record.tenant_id, email)
    user === nothing && throw(AuthError("UNAUTHORIZED", "User email is not active for this tenant"; status = 401))
    session_id = string(uuid4())
    expires_at = now() + Hour(UI_SESSION_TTL_HOURS)
    _persist_ui_session!(store, session_id, auth_record.tenant_id, user[:id], expires_at)
    return (cookie = signed_session_cookie(session_id, config.tenant.session_secret), expires_at = expires_at, user_id = string(user[:id]))
end

function _protected_ui_context_and_store(services::AppServices)
    request = _auth_request_from_http()
    return _protected_context_and_store(services; request = request)
end

function handle_login_page(services::AppServices)
    next = _safe_ui_next(get(_query_params_dict(), "next", "/dashboard"))
    return _html_response(render_login_page(next = next))
end

function handle_login(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/login")
        store = _store_for_services(services)
        payload = _login_payload()
        session = authenticate_ui_login!(store, services.config, payload)
        next = _safe_ui_next(_payload_get(payload, "next", "/dashboard"))
        cookie = string(UI_SESSION_COOKIE, "=", session.cookie, "; HttpOnly; SameSite=Lax; Path=/")
        return HTTP.Response(303, ["Location" => next, "Set-Cookie" => cookie, "Cache-Control" => "no-store"], "")
    catch err
        message = err isa AuthError || err isa ApiError ? err.message : "Unable to sign in"
        return _html_response(render_login_page(error = message); status = 401)
    end
end

function handle_logout(_services::AppServices)
    cookie = string(UI_SESSION_COOKIE, "=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0")
    return HTTP.Response(303, ["Location" => "/login", "Set-Cookie" => cookie, "Cache-Control" => "no-store"], "")
end

function handle_dashboard(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_dashboard_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fdashboard")
        return _html_response("<h1>Dashboard unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_imports_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_import_center_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fimports")
        return _html_response("<h1>Imports unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_warehouses_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_warehouses_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fwarehouses")
        return _html_response("<h1>Warehouses unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_create_warehouse_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/warehouses")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_warehouse_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/warehouses")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fwarehouses")
        return _ui_action_failure_response("Warehouse action failed", err)
    end
end

function handle_update_warehouse_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/warehouses/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_warehouse_ui_form!(store, ctx, _form_payload(); warehouse_id = Router.params(:id))
        return _redirect_response("/warehouses")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fwarehouses")
        return _ui_action_failure_response("Warehouse action failed", err)
    end
end

function handle_skus_page(services::AppServices)
    try
        ctx, store = _protected_ui_context_and_store(services)
        html = render_skus_page(store, ctx)
        return _html_response(html)
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fskus")
        return _html_response("<h1>SKUs unavailable</h1><p>$(_h(sprint(showerror, err)))</p>"; status = 500)
    end
end

function handle_create_sku_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/skus")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_sku_ui_form!(store, ctx, _form_payload())
        return _redirect_response("/skus")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fskus")
        return _ui_action_failure_response("SKU action failed", err)
    end
end

function handle_update_sku_form(services::AppServices)
    try
        _enforce_route_rate_limit!(services, "POST", "/skus/:id")
        ctx, store = _protected_ui_context_and_store(services)
        _apply_sku_ui_form!(store, ctx, _form_payload(); sku_id = Router.params(:id))
        return _redirect_response("/skus")
    catch err
        err isa AuthError && return _redirect_response("/login?next=%2Fskus")
        return _ui_action_failure_response("SKU action failed", err)
    end
end
