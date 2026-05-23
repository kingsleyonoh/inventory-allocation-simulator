# Inventory Allocation Simulator — Product Baseline

Users: supply-chain planners, distributors, retailers, operations admins, read-only stakeholders.

Positioning: dense, explainable operations console for allocation planning. The product helps decide where scarce inventory should sit before demand arrives, with tenant-scoped CSV/API inputs and optional ecosystem adapters.

Product personality: operational, precise, trustworthy, low decoration, fast path to scenario comparison and approval decisions.

Trust requirements:
- Every recommendation exposes net value, confidence, binding constraints, scenario sensitivity, and accepted tradeoffs.
- Tenant isolation and role permissions must be visible in controls and enforced server-side.
- Local CSV/manual workflows work without Notification Hub, Workflow Engine, or Delivery Gateway.

Anti-references:
- Not a BI dashboard builder.
- Not an ERP writeback tool.
- Not a black-box ML forecasting product.
- Not a mobile-first consumer app.
