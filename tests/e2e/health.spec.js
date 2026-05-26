const fs = require('fs');
const path = require('path');

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

test.describe('real HTTP smoke', () => {
  test('GET /health reports the running Inventory Allocation Simulator process', async ({ request }) => {
    const response = await request.get('/health');
    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(body).toEqual({
      status: 'ok',
      service: 'inventory-allocation-simulator',
    });
  });

  test('GET /health/ready reports migration readiness over real HTTP', async ({ request }) => {
    const response = await request.get('/health/ready');
    expect([200, 503]).toContain(response.status());
    const body = await response.json();
    expect(['ready', 'not_ready']).toContain(body.status);
    expect(body.database.service).toBe('postgresql');
  });

  test('GET /metrics requires and accepts the internal token over real HTTP', async ({ request }) => {
    const unauthorized = await request.get('/metrics');
    expect(unauthorized.status()).toBe(401);
    expect(await unauthorized.text()).toContain('metrics token required');

    const authorized = await request.get('/metrics', { headers: { 'X-Metrics-Token': 'e2e-metrics-token-placeholder' } });
    expect(authorized.status()).toBe(200);
    const body = await authorized.text();
    expect(body).toContain('inventory_allocation_app_up 1');
    expect(body).not.toContain('e2e-metrics-token-placeholder');
  });

  test('unknown routes return HTTP 404 over the real server', async ({ request }) => {
    const response = await request.get('/__missing_smoke_route__');
    expect(response.status()).toBe(404);
  });
});
