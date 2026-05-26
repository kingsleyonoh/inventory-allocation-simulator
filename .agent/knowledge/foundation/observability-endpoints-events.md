# Observability Endpoints and Events

## What it establishes

Prometheus metrics, readiness health, local error persistence, and local analytics event contracts are exposed through one observability primitive with secret-safe output and optional PostHog configuration.

## Files

- `src/observability/logging.jl` — structured JSON request/job log helpers.
- `src/observability/metrics_errors_analytics.jl` — metrics auth/rendering, readiness composition, local error event builder, and local analytics event builder/persistence helpers.
- `config/routes.jl` — production `/metrics` and `/health/ready` route wiring.
- `config/prometheus/alerts.yml` — Prometheus alert rule definitions for failures, dead letters, DB outage, and solver p95.
- `migrations/008_observability_events.up.sql` — local error and analytics event tables.
- `tests/unit/setup/test_batch039_observability_endpoints.jl` — endpoint, event, migration, alert, and config coverage.
- `tests/e2e/health.spec.js` — real HTTP health/metrics smoke coverage.

## When to read this

Before writing any code that:
- Adds or changes `/metrics`, `/health`, `/health/db`, or `/health/ready` behavior.
- Emits local error events or local analytics events.
- Adds new observability environment variables or alert rules.
- Sends optional analytics to PostHog or another third-party tracking service.

## Contract

- `/metrics` must be protected by `METRICS_TOKEN`, accepted only through `X-Metrics-Token` or `Authorization: Bearer <token>`, and must never render the token in the Prometheus body.
- `/health/ready` composes DB migration health; it returns `ready` only when `/health/db` would be `ok` and migrations are current.
- Local observability tables are data-bearing and include `tenant_id`; system-level errors may store `tenant_id` as `NULL` when no tenant context exists.
- Local analytics is canonical and works without PostHog; `POSTHOG_ENABLED` defaults false and PostHog credentials are read only from config/env.
- Local error and analytics builders validate nonblank event types; callers should prefer key funnel event names such as `import.created`, `import.failed`, `simulation.started`, `simulation.failed`, `recommendation.approved`, and `recommendation.exported`.
- Alert rules live in `config/prometheus/alerts.yml`; do not hardcode deployment-specific thresholds or credentials into rule annotations.

## Cross-references

- PRD §10b Observability
- `.agent/knowledge/foundation/core-config-loading.md`
- `.agent/knowledge/foundation/db-migration-runner.md`
- `.agent/knowledge/foundation/service-dependency-injection.md`
