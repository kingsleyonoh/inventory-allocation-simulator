CREATE TABLE IF NOT EXISTS allocation_policies (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL,
    objective TEXT NOT NULL CHECK (objective IN ('minimize_stockout_cost', 'maximize_margin', 'minimize_total_cost', 'balanced')),
    planning_horizon_days INTEGER NOT NULL CHECK (planning_horizon_days BETWEEN 1 AND 180),
    service_level_target NUMERIC(5,4) NOT NULL CHECK (service_level_target > 0 AND service_level_target <= 1),
    max_transfer_cost_cents INTEGER NULL,
    allow_cross_region BOOLEAN NOT NULL DEFAULT true,
    frozen_until DATE NULL,
    config JSONB NOT NULL DEFAULT '{}',
    status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'archived')),
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS allocation_policies_tenant_status_idx ON allocation_policies (tenant_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS allocation_policies_tenant_name_idx ON allocation_policies (tenant_id, name);

CREATE TABLE IF NOT EXISTS simulation_runs (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    policy_id UUID NOT NULL REFERENCES allocation_policies(id),
    name TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
    input_snapshot JSONB NOT NULL,
    scenario_count INTEGER NOT NULL DEFAULT 0,
    started_at TIMESTAMP NULL,
    completed_at TIMESTAMP NULL,
    error_message TEXT NULL,
    created_by_user_id UUID NULL REFERENCES users(id),
    idempotency_key TEXT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS simulation_runs_tenant_status_created_idx ON simulation_runs (tenant_id, status, created_at);
CREATE INDEX IF NOT EXISTS simulation_runs_tenant_policy_created_idx ON simulation_runs (tenant_id, policy_id, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS simulation_runs_tenant_idempotency_key_idx ON simulation_runs (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS demand_scenarios (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    simulation_run_id UUID NOT NULL REFERENCES simulation_runs(id),
    scenario_index INTEGER NOT NULL,
    probability_weight NUMERIC(8,6) NOT NULL,
    demand_payload JSONB NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS demand_scenarios_tenant_run_index_idx ON demand_scenarios (tenant_id, simulation_run_id, scenario_index);

CREATE TABLE IF NOT EXISTS allocation_recommendations (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    simulation_run_id UUID NOT NULL REFERENCES simulation_runs(id),
    from_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    to_warehouse_id UUID NOT NULL REFERENCES warehouses(id),
    sku_id UUID NOT NULL REFERENCES skus(id),
    transfer_units NUMERIC(14,2) NOT NULL CHECK (transfer_units > 0),
    expected_stockout_reduction_units NUMERIC(14,2) NOT NULL DEFAULT 0,
    expected_margin_gain_cents INTEGER NOT NULL DEFAULT 0,
    transfer_cost_cents INTEGER NOT NULL DEFAULT 0,
    net_value_cents INTEGER NOT NULL DEFAULT 0,
    confidence_score NUMERIC(5,4) NOT NULL CHECK (confidence_score >= 0 AND confidence_score <= 1),
    explanation JSONB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('proposed', 'approved', 'rejected', 'exported', 'expired')),
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS allocation_recommendations_tenant_run_status_idx ON allocation_recommendations (tenant_id, simulation_run_id, status);
CREATE INDEX IF NOT EXISTS allocation_recommendations_tenant_sku_status_idx ON allocation_recommendations (tenant_id, sku_id, status);
CREATE INDEX IF NOT EXISTS allocation_recommendations_tenant_lane_idx ON allocation_recommendations (tenant_id, from_warehouse_id, to_warehouse_id);

CREATE TABLE IF NOT EXISTS recommendation_decisions (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    recommendation_id UUID NOT NULL REFERENCES allocation_recommendations(id),
    user_id UUID NULL REFERENCES users(id),
    decision TEXT NOT NULL CHECK (decision IN ('approved', 'rejected', 'exported', 'expired')),
    reason TEXT NULL,
    decided_at TIMESTAMP NOT NULL DEFAULT now(),
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS recommendation_decisions_tenant_recommendation_decided_idx ON recommendation_decisions (tenant_id, recommendation_id, decided_at);

CREATE TABLE IF NOT EXISTS import_jobs (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    import_type TEXT NOT NULL CHECK (import_type IN ('warehouses', 'skus', 'inventory', 'demand', 'lanes')),
    status TEXT NOT NULL CHECK (status IN ('uploaded', 'queued', 'running', 'completed', 'failed')),
    original_filename TEXT NOT NULL,
    file_path TEXT NOT NULL,
    row_count INTEGER NOT NULL DEFAULT 0,
    error_report JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS import_jobs_tenant_status_created_idx ON import_jobs (tenant_id, status, created_at);
CREATE INDEX IF NOT EXISTS import_jobs_tenant_type_created_idx ON import_jobs (tenant_id, import_type, created_at);

CREATE TABLE IF NOT EXISTS ecosystem_outbox (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    event_type TEXT NOT NULL,
    event_id TEXT NOT NULL UNIQUE,
    payload JSONB NOT NULL,
    target TEXT NOT NULL CHECK (target IN ('notification_hub', 'workflow_engine')),
    status TEXT NOT NULL CHECK (status IN ('queued', 'sending', 'sent', 'failed', 'dead_letter')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMP NOT NULL DEFAULT now(),
    last_error TEXT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ecosystem_outbox_tenant_status_next_attempt_idx ON ecosystem_outbox (tenant_id, status, next_attempt_at);
CREATE INDEX IF NOT EXISTS ecosystem_outbox_tenant_target_created_idx ON ecosystem_outbox (tenant_id, target, created_at);
