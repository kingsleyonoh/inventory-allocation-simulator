ALTER TABLE allocation_policies
    DROP CONSTRAINT IF EXISTS allocation_policies_recommendation_expiry_days_positive;

ALTER TABLE users
    DROP COLUMN IF EXISTS notification_opt_outs;
