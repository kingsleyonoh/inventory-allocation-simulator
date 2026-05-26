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

function composeServiceNames() {
  const result = spawnSync('docker', ['compose', 'ps', '--services', '--filter', 'status=running'], {
    cwd: process.cwd(),
    env: process.env,
    encoding: 'utf8',
    windowsHide: true,
  });
  expect(result.status, result.stderr).toBe(0);
  return result.stdout.split(/\r?\n/).filter(Boolean);
}

test.describe('running server with PostgreSQL and Redis', () => {
  test('Docker Compose services and real HTTP readiness are exercised together', async ({ request }) => {
    const services = composeServiceNames();
    expect(services).toContain('postgres');
    expect(services).toContain('redis');

    const db = await request.get('/health/db');
    expect([200, 503]).toContain(db.status());
    const dbBody = await db.json();
    expect(dbBody.service).toBe('postgresql');
    expect(dbBody.migrations || dbBody.error).toBeTruthy();

    const ready = await request.get('/health/ready');
    expect([200, 503]).toContain(ready.status());
    const readyBody = await ready.json();
    expect(['ready', 'not_ready']).toContain(readyBody.status);
    expect(readyBody.database.service).toBe('postgresql');
  });
});
