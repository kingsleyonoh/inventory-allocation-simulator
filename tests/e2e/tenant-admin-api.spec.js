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
  test('protected tenant and user routes fail closed without authentication', async ({ request }) => {
    for (const path of ['/tenants/me', '/api/settings/tenant', '/api/users']) {
      const response = await request.get(path);
      expect(response.status(), `${path} status`).toBe(401);
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
