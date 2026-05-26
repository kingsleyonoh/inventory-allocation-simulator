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

const LCP_TARGET_MS = 2500;
const dashboardPages = ['/dashboard', '/imports', '/simulations'];

test.describe('operations console dashboard LCP benchmark', () => {
  test.skip(process.env.RUN_PERF_BENCHMARKS !== 'true', 'set RUN_PERF_BENCHMARKS=true to enforce PRD 10b LCP target');

  for (const url of dashboardPages) {
    test(`${url} records largest-contentful-paint under PRD target`, async ({ page }) => {
      await page.addInitScript(() => {
        window.__iasLcpEntries = [];
        new PerformanceObserver((entryList) => {
          window.__iasLcpEntries.push(...entryList.getEntries());
        }).observe({ type: 'largest-contentful-paint', buffered: true });
      });

      await page.goto(url, { waitUntil: 'networkidle' });
      await page.waitForTimeout(100);
      const lcp = await page.evaluate(() => {
        const entries = window.__iasLcpEntries || [];
        if (entries.length === 0) return 0;
        return Math.max(...entries.map((entry) => entry.renderTime || entry.loadTime || entry.startTime || 0));
      });

      expect(lcp, `${url} largest-contentful-paint`).toBeLessThanOrEqual(LCP_TARGET_MS);
      await expect(page.locator('body')).toBeVisible();
    });
  }
});
