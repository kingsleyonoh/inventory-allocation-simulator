DROP INDEX IF EXISTS simulation_runs_tenant_idempotency_key_idx;

ALTER TABLE simulation_runs DROP COLUMN IF EXISTS idempotency_key;
