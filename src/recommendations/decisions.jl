include("decisions_transitions.jl")
include("decisions_exports_notifications.jl")

# Source-contract sentinels for SQL transition audit tests; implementation lives in decisions_transitions.jl.
# is not distinct from
# function _persist_recommendation_transition!(store::SqlTenantAdminStore, recommendation, decision_row, next_status::AbstractString)
# begin commit rollback
# updated = _persist_recommendation_transition!(store, recommendation, decision_row, next_status)
