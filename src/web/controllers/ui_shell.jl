using Genie.Requests
using HTTP

const UI_SESSION_COOKIE = "ias_session"
const UI_SESSION_TTL_HOURS = 12

const UI_APP_SHELL_STYLE = """
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
"""


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
$(UI_APP_SHELL_STYLE)
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

