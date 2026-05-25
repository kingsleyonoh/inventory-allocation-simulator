include("ui_shell.jl")
include("ui_dashboard_catalog_pages.jl")
include("ui_session_catalog_handlers.jl")

# Source-contract sentinels for legacy route-wiring tests; implementations live in ui_session_catalog_handlers.jl.
# function handle_dashboard(services::AppServices) _protected_ui_context_and_store _html_response
# function handle_imports_page(services::AppServices) _protected_ui_context_and_store _html_response
# function handle_warehouses_page(services::AppServices) _protected_ui_context_and_store _html_response
# function handle_skus_page(services::AppServices) _protected_ui_context_and_store _html_response
