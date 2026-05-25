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

test.describe('operations console UI over real HTTP', () => {
  test('login page is reachable and protected dashboard redirects to sign in', async ({ page }) => {
    await page.goto('/login');
    await expect(page.getByRole('heading', { name: 'Operations console sign in' })).toBeVisible();
    await expect(page.getByLabel('Tenant API key')).toBeVisible();
    await expect(page.getByLabel('User email')).toBeVisible();

    await page.goto('/dashboard');
    await expect(page).toHaveURL(/\/login\?next=%2Fdashboard$/);
    await expect(page.getByRole('heading', { name: 'Operations console sign in' })).toBeVisible();
  });

  test('catalog management form routes fail closed over real HTTP', async ({ request }) => {
    const formRoutes = [
      ['/warehouses', { code: 'lon', name: 'London DC', region: 'GB-LDN', capacity_units: '420' }, /\/login\?next=%2Fwarehouses$/],
      ['/warehouses/10000000-0000-4000-8000-000000000001', { active: 'false' }, /\/login\?next=%2Fwarehouses$/],
      ['/skus', { sku_code: 'sku-gold', name: 'Gold Widget', category: 'widgets' }, /\/login\?next=%2Fskus$/],
      ['/skus/30000000-0000-4000-8000-000000000001', { active: 'false' }, /\/login\?next=%2Fskus$/],
    ];

    for (const [url, form, expectedLocation] of formRoutes) {
      const response = await request.post(url, { form, maxRedirects: 0 });
      expect(response.status(), `POST ${url} status`).toBe(303);
      expect(response.headers().location, `POST ${url} redirect`).toMatch(expectedLocation);
    }
  });
});
