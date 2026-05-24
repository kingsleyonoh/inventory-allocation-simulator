ALTER TABLE simulation_runs ADD COLUMN IF NOT EXISTS idempotency_key TEXT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS simulation_runs_tenant_idempotency_key_idx
    ON simulation_runs (tenant_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
