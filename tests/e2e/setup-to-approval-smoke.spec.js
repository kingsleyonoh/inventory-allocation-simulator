const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function findPlaywrightTestModule(start) {
  let dir = path.dirname(start);
  while (dir && dir !== path.dirname(dir)) {
    const candidate = path.join(dir, 'test.js');
    const pkg = path.join(dir, 'package.json');
    if (fs.existsSync(candidate) && fs.existsSync(pkg)) {
      const meta = JSON.parse(fs.readFileSync(pkg, 'utf8'));
      if (meta.name === 'playwright') return candidate;
    }
    dir = path.dirname(dir);
  }
  throw new Error('Unable to locate Playwright test module from npx runtime');
}

const { test, expect } = require(findPlaywrightTestModule(process.argv[1]));

const repoRoot = path.resolve(__dirname, '..', '..');
const helperPath = path.join(repoRoot, 'tests', 'e2e', 'helpers', 'setup_to_approval_fixture.jl');
const csvFixtures = {
  warehouses: path.join(repoRoot, 'tests', 'fixtures', 'csv', 'warehouses.csv'),
  skus: path.join(repoRoot, 'tests', 'fixtures', 'csv', 'skus.csv'),
  inventory: path.join(repoRoot, 'tests', 'fixtures', 'csv', 'inventory.csv'),
  demand: path.join(repoRoot, 'tests', 'fixtures', 'csv', 'demand_history.csv'),
  lanes: path.join(repoRoot, 'tests', 'fixtures', 'csv', 'transfer_lanes.csv'),
};

function e2eEnv() {
  const postgresPort = process.env.POSTGRES_PORT || '55432';
  const postgresUser = process.env.POSTGRES_USER || 'inventory';
  const postgresPassword = process.env.POSTGRES_PASSWORD || 'your-password-here';
  const postgresDb = process.env.POSTGRES_DB || 'inventory_allocation';
  const inheritedDatabaseUrl = process.env.DATABASE_URL || '';
  const databaseUrl = inheritedDatabaseUrl.includes('placeholder-password') || inheritedDatabaseUrl.length === 0
    ? `postgres://${postgresUser}:${postgresPassword}@127.0.0.1:${postgresPort}/${postgresDb}` // isolated local Docker default
    : inheritedDatabaseUrl;
  return {
    ...process.env,
    APP_ENV: process.env.APP_ENV || 'test',
    POSTGRES_PORT: postgresPort,
    POSTGRES_USER: postgresUser,
    POSTGRES_PASSWORD: postgresPassword,
    POSTGRES_DB: postgresDb,
    DATABASE_URL: databaseUrl,
    REDIS_URL: process.env.REDIS_URL || 'redis://localhost:6379/0',
    DUCKDB_PATH: process.env.DUCKDB_PATH || './data/e2e-backtests.duckdb',
    SESSION_SECRET: process.env.SESSION_SECRET || 'e2e-session-secret-placeholder',
    METRICS_TOKEN: process.env.METRICS_TOKEN || 'e2e-metrics-token-placeholder',
  };
}

function runJulia(args) {
  const result = spawnSync('julia', ['--project', ...args], {
    cwd: repoRoot,
    env: e2eEnv(),
    encoding: 'utf8',
    windowsHide: true,
  });
  if (result.status !== 0) {
    throw new Error(`julia ${args.join(' ')} failed with ${result.status}\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}`);
  }
  return result.stdout.trim();
}

function runFixture(args) {
  const stdout = runJulia([helperPath, ...args]);
  const line = stdout.split(/\r?\n/).filter(Boolean).at(-1);
  return JSON.parse(line);
}

test.describe('setup/login/import/simulation/approval smoke over real HTTP', () => {
  test.setTimeout(420_000);
  let fixture;

  test.beforeAll(() => {
    runJulia(['scripts/migrate.jl', 'down']);
    runJulia(['scripts/migrate.jl', 'up']);
    const runId = `${Date.now()}-${process.pid}`.replace(/[^0-9A-Za-z-]/g, '-');
    fixture = runFixture(['run-setup', runId]);
  });

  test('self-hosted setup user imports sample data, runs simulation, and approves recommendation', async ({ page, request }) => {
    const authHeaders = { 'X-API-Key': fixture.apiKey };

    const profile = await request.get('/tenants/me', { headers: authHeaders });
    expect(profile.status()).toBe(200);
    await expect(profile).toBeOK();
    expect((await profile.json()).display_name).toContain('E2E Smoke');
    expect(fixture.apiKey).toMatch(/^ias_/);

    await page.goto('/login');
    await page.getByLabel('Tenant API key').fill(fixture.apiKey);
    await page.getByLabel('User email').fill(fixture.email);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard$/);
    await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();

    const importOrder = ['warehouses', 'skus', 'inventory', 'demand', 'lanes'];
    for (const importType of importOrder) {
      const response = await request.post('/api/imports', {
        headers: authHeaders,
        data: {
          import_type: importType,
          original_filename: path.basename(csvFixtures[importType]),
          content: fs.readFileSync(csvFixtures[importType], 'utf8'),
        },
      });
      const job = await response.json();
      expect(response.status(), `import ${importType} upload status: ${JSON.stringify(job)}`).toBe(202);
      expect(job.status).toBe('queued');
      const processed = runFixture(['process-import', fixture.apiKey, job.id]);
      expect(processed.status, `import ${importType} worker status`).toBe('completed');
      expect(processed.row_count, `import ${importType} row count`).toBeGreaterThan(0);
    }

    const policyResponse = await request.post('/api/policies', {
      headers: authHeaders,
      data: {
        name: `Batch 031 Smoke Policy ${Date.now()}`,
        objective: 'balanced',
        planning_horizon_days: 14,
        service_level_target: 0.95,
        max_transfer_cost_cents: 100000,
        allow_cross_region: true,
        config: {},
        status: 'active',
      },
    });
    expect(policyResponse.status()).toBe(201);
    const policy = await policyResponse.json();

    const simulationResponse = await request.post('/api/simulations', {
      headers: authHeaders,
      data: { policy_id: policy.id, name: 'Batch 031 smoke simulation', scenario_count: 3 },
    });
    const run = await simulationResponse.json();
    expect(simulationResponse.status(), `simulation create status: ${JSON.stringify(run)}`).toBe(202);
    expect(run.status).toBe('queued');

    const completedRun = runFixture(['run-simulation', fixture.apiKey]);
    expect(completedRun.status).toBe('completed');
    expect(completedRun.id).toBe(run.id);

    const recommendationsResponse = await request.get(`/api/recommendations?status=proposed&limit=25`, { headers: authHeaders });
    expect(recommendationsResponse.status()).toBe(200);
    const recommendations = await recommendationsResponse.json();
    expect(recommendations.recommendations.length).toBeGreaterThan(0);
    const recommendation = recommendations.recommendations[0];
    expect(recommendation.status).toBe('proposed');
    expect(recommendation.net_value_cents).toBeGreaterThan(0);

    const approval = await request.post(`/api/recommendations/${recommendation.id}/approve`, {
      headers: authHeaders,
      data: { reason: 'Batch 031 Playwright smoke approval' },
    });
    expect(approval.status()).toBe(200);
    const decision = await approval.json();
    expect(decision.recommendation.status).toBe('approved');
    expect(decision.decision.decision).toBe('approved');
  });

  test('setup-to-approval smoke rejects unauthenticated import and approval actions', async ({ request }) => {
    const importResponse = await request.post('/api/imports', {
      multipart: {
        import_type: 'warehouses',
        file: {
          name: 'warehouses.csv',
          mimeType: 'text/csv',
          buffer: fs.readFileSync(csvFixtures.warehouses),
        },
      },
    });
    expect(importResponse.status()).toBe(401);
    expect((await importResponse.json()).error.code).toBe('UNAUTHORIZED');

    const approval = await request.post('/api/recommendations/00000000-0000-4000-8000-000000000000/approve', {
      data: { reason: 'not authenticated' },
    });
    expect(approval.status()).toBe(401);
    expect((await approval.json()).error.code).toBe('UNAUTHORIZED');
  });
});
