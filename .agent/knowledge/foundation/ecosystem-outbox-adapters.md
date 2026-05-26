# Ecosystem Outbox Adapters

## What it establishes

Optional ecosystem integrations use strict event envelopes, tenant-derived notification payload tokens, and persisted `ecosystem_outbox` rows so Notification Hub and Workflow Engine failures never block core recommendation truth.

## Files

- `src/events/envelope.jl` — event envelope creation and required-token validation
- `src/integrations/http_client.jl` — shared HTTP POST and adapter config guards
- `src/integrations/notification_hub.jl` — Notification Hub payload builder/enqueue/dispatch path
- `src/integrations/workflow_engine.jl` — Workflow Engine enqueue/dispatch path
- `src/jobs/outbox_jobs.jl` — outbox dispatcher retry, exponential backoff, dead-letter, and benchmark helper
- `tests/unit/api/test_batch036_ecosystem_integrations.jl` — correctness coverage for disabled/enabled/failing adapters and 60-second dispatch benchmark

## When to read this

Before writing any code that:
- Emits Notification Hub or Workflow Engine events
- Adds or changes payload tokens used by external templates/workflows
- Touches `ecosystem_outbox` status, retry, or dead-letter behavior
- Adds a new optional ecosystem adapter

## Contract

- Optional adapter flags default off; disabled adapters no-op at enqueue time and do not block local simulation, approval, notification, or export flows.
- Notification Hub receives `{ event_type, event_id, tenant_id, payload }` at `POST /api/events`; Workflow Engine receives `{ trigger_data: payload }` at `POST /api/workflows/{workflow_id}/execute`.
- Required payload tokens must be present and non-blank before an outbox row is created. Missing tokens raise `ApiError("VALIDATION_ERROR", ...)` instead of creating a malformed event.
- Tenant identity tokens come from tenant records (`display_name`, `contact.email`) and recommendation/run facts come from local records; never hardcode tenant identity or reread mutable state for completed snapshots outside the payload builder's source records.
- Dispatcher status flow is `queued|failed -> sending -> sent|failed|dead_letter`; transient failures retry with exponential backoff, permanent 4xx and exhausted attempts dead-letter.
- Downstream API keys are read from `AppConfig.integrations`; never log or expose them in payloads.

## Cross-references

- PRD §5.7 Ecosystem Adapter Module
- PRD §6b Ecosystem Integration Points
- PRD §7 Scheduler / Background Jobs
- PRD §10b Performance & Observability
