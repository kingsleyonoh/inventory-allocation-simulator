CREATE TABLE IF NOT EXISTS local_error_events (
    id UUID PRIMARY KEY,
    tenant_id UUID NULL REFERENCES tenants(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    source TEXT NOT NULL,
    message TEXT NOT NULL,
    request_id TEXT NULL,
    details JSONB NOT NULL DEFAULT '{}',
    occurred_at TIMESTAMP NOT NULL DEFAULT now(),
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS local_error_events_tenant_created_idx ON local_error_events (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS local_error_events_type_created_idx ON local_error_events (event_type, created_at DESC);

CREATE TABLE IF NOT EXISTS local_analytics_events (
    id UUID PRIMARY KEY,
    tenant_id UUID NULL REFERENCES tenants(id) ON DELETE SET NULL,
    user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    properties JSONB NOT NULL DEFAULT '{}',
    occurred_at TIMESTAMP NOT NULL DEFAULT now(),
    created_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS local_analytics_events_tenant_type_created_idx ON local_analytics_events (tenant_id, event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS local_analytics_events_created_idx ON local_analytics_events (created_at DESC);
