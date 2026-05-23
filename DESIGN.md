# Inventory Allocation Simulator — Design Baseline

Visual tone: dense operations console, high-information tables, clear hierarchy, minimal decoration.

Layout:
- Desktop primary.
- Tablet retains tables with horizontal scroll.
- 390px mobile supports dashboard, run status, approve/reject actions; bulk CSV import may warn that desktop is recommended.

Core components:
- KPI cards for stockout risk, pending recommendations, recent failures.
- Data tables with filters, status badges, row actions, captions, and keyboard focus.
- Scenario comparison panels with confidence and net-value emphasis.
- Recommendation explanation drawer/detail view.
- Adapter health cards with disabled/failing states.

Accessibility:
- WCAG 2.1 AA.
- semantic headings, labels, table captions, alert roles.
- Visible focus rings and keyboard navigation for menus, forms, dialogs, and approvals.
- no color-only confidence or status signaling.

Interaction states:
loading, empty, invalid import, solver running, solver failed, infeasible model, recommendation expired, adapter disabled, adapter failed, permission denied.

Performance:
- lazy-load charting only on simulation detail routes.
- Dashboard LCP target under 2.5s.

Privacy and consent:
- uploaded CSV data stays local to tenant boundaries.
- Exports and integration sends require explicit user action before data leaves the tenant workflow.

Required evidence: MOBILE_VIEWPORT_PASS, ACCESSIBILITY_AA_PASS, FRONTEND_IMPECCABLE_AUDIT_PASS, BUNDLE_DYNAMIC_IMPORT_AUDIT_PASS.
