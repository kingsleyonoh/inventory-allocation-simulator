UPDATE simulation_runs
SET scenario_count = 100
WHERE scenario_count < 1 OR scenario_count > 100;

ALTER TABLE simulation_runs
    ALTER COLUMN scenario_count SET DEFAULT 100;

ALTER TABLE simulation_runs
    DROP CONSTRAINT IF EXISTS simulation_runs_scenario_count_bounds;

ALTER TABLE simulation_runs
    ADD CONSTRAINT simulation_runs_scenario_count_bounds
    CHECK (scenario_count BETWEEN 1 AND 100);
