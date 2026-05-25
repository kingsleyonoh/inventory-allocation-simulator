CREATE TABLE IF NOT EXISTS local_notifications (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenants(id),
    user_id UUID NULL REFERENCES users(id),
    event_type TEXT NOT NULL,
    event_id TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    read_at TIMESTAMP NULL,
    source_record_type TEXT NOT NULL CHECK (source_record_type IN ('simulation_run', 'allocation_recommendation', 'integration_adapter', 'backtest')),
    source_record_id UUID NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

DROP INDEX IF EXISTS local_notifications_tenant_event_idx;
CREATE UNIQUE INDEX IF NOT EXISTS local_notifications_tenant_event_user_idx
    ON local_notifications (tenant_id, event_id, user_id) NULLS NOT DISTINCT;
CREATE INDEX IF NOT EXISTS local_notifications_tenant_user_read_created_idx ON local_notifications (tenant_id, user_id, read_at, created_at);
CREATE INDEX IF NOT EXISTS local_notifications_tenant_event_type_created_idx ON local_notifications (tenant_id, event_type, created_at);
CREATE INDEX IF NOT EXISTS local_notifications_tenant_source_idx ON local_notifications (tenant_id, source_record_type, source_record_id);
