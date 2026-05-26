const { spawn, spawnSync } = require('child_process');

function e2eEnvironment() {
  const env = { ...process.env };
  env.POSTGRES_PORT = env.POSTGRES_PORT || '55432';
  env.POSTGRES_USER = env.POSTGRES_USER || 'inventory';
  env.POSTGRES_PASSWORD = env.POSTGRES_PASSWORD || 'your-password-here';
  env.POSTGRES_DB = env.POSTGRES_DB || 'inventory_allocation';
  env.DATABASE_URL = env.DATABASE_URL || `postgres://${env.POSTGRES_USER}:${env.POSTGRES_PASSWORD}@127.0.0.1:${env.POSTGRES_PORT}/${env.POSTGRES_DB}`;
  return env;
}

const env = e2eEnvironment();

function runDockerComposeUp() {
  const result = spawnSync('docker', ['compose', 'up', '-d', '--wait', 'postgres', 'redis'], {
    cwd: process.cwd(),
    env,
    encoding: 'utf8',
    stdio: ['ignore', 'inherit', 'inherit'],
    windowsHide: true,
  });
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
}

function startJuliaServer() {
  const child = spawn('julia', ['--project', 'src/Main.jl'], {
    cwd: process.cwd(),
    env,
    stdio: 'inherit',
    windowsHide: true,
  });

  const stop = (signal) => {
    if (!child.killed) child.kill(signal);
  };
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));
  child.on('exit', (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    process.exit(code || 0);
  });
}

runDockerComposeUp();
startJuliaServer();
