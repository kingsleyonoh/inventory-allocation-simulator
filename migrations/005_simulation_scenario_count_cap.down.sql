ALTER TABLE simulation_runs
    DROP CONSTRAINT IF EXISTS simulation_runs_scenario_count_bounds;

ALTER TABLE simulation_runs
    ALTER COLUMN scenario_count SET DEFAULT 0;
