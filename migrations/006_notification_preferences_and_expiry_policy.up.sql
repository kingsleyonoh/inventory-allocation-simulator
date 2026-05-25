ALTER TABLE users
    ADD COLUMN IF NOT EXISTS notification_opt_outs JSONB NOT NULL DEFAULT '{}';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'allocation_policies_recommendation_expiry_days_positive'
    ) THEN
        ALTER TABLE allocation_policies
            ADD CONSTRAINT allocation_policies_recommendation_expiry_days_positive
            CHECK (
                CASE
                    WHEN config ? 'recommendation_expiry_days' THEN
                        jsonb_typeof(config -> 'recommendation_expiry_days') = 'number'
                        AND (config ->> 'recommendation_expiry_days')::int > 0
                    ELSE true
                END
            );
    END IF;
END $$;
