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

test.describe('tenant admin API routes over real HTTP', () => {
  test('protected tenant, user, API-key, warehouse, and SKU routes fail closed without authentication', async ({ request }) => {
    const probes = [
      ['get', '/tenants/me'],
      ['get', '/api/settings/tenant'],
      ['get', '/api/users'],
      ['post', '/api/settings/api-key/rotate'],
      ['get', '/api/warehouses'],
      ['post', '/api/warehouses'],
      ['get', '/api/skus'],
      ['post', '/api/skus'],
      ['get', '/api/inventory'],
      ['put', '/api/inventory/50000000-0000-4000-8000-000000000001'],
      ['get', '/api/demand-history'],
      ['get', '/api/lanes'],
      ['post', '/api/lanes'],
    ];
    for (const [method, path] of probes) {
      const response = await request[method](path, { data: {} });
      expect(response.status(), `${method.toUpperCase()} ${path} status`).toBe(401);
      const body = await response.json();
      expect(body.error.code).toBe('UNAUTHORIZED');
    }
  });

  test('self-registration route is wired and honors disabled guard before persistence', async ({ request }) => {
    const response = await request.post('/api/tenants/register', { data: { name: 'Blocked Tenant' } });
    expect(response.status()).toBe(403);
    const body = await response.json();
    expect(body.error.code).toBe('FORBIDDEN');
    expect(body.error.message).toContain('Self-registration is disabled');
  });
});
