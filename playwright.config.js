// @ts-check

const host = process.env.APP_HOST || '127.0.0.1';
const port = process.env.APP_PORT || '8125';
const baseURL = process.env.PUBLIC_BASE_URL || `http://${host}:${port}`;

module.exports = {
  testDir: 'tests/e2e',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  retries: process.env.CI ? 1 : 0,
  use: {
    baseURL,
    trace: 'retain-on-failure',
  },
  webServer: {
    command: 'julia --project src/Main.jl',
    url: `${baseURL}/health`,
    reuseExistingServer: !process.env.CI,
    timeout: 90_000,
    env: {
      ...process.env,
      APP_ENV: process.env.APP_ENV || 'test',
      APP_HOST: host,
      APP_PORT: port,
      PUBLIC_BASE_URL: baseURL,
      DATABASE_URL: process.env.DATABASE_URL || 'postgres://inventory:placeholder-password@localhost:5432/inventory_allocation',
      REDIS_URL: process.env.REDIS_URL || 'redis://localhost:6379/0',
      DUCKDB_PATH: process.env.DUCKDB_PATH || './data/e2e-backtests.duckdb',
      SESSION_SECRET: process.env.SESSION_SECRET || 'e2e-session-secret-placeholder',
      METRICS_TOKEN: process.env.METRICS_TOKEN || 'e2e-metrics-token-placeholder',
      SELF_REGISTRATION_ENABLED: process.env.SELF_REGISTRATION_ENABLED || 'false',
    },
  },
};
