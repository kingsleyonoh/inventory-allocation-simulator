DROP INDEX IF EXISTS local_notifications_tenant_event_user_idx;
CREATE UNIQUE INDEX IF NOT EXISTS local_notifications_tenant_event_idx
    ON local_notifications (tenant_id, event_id);
