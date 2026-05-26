# VPS Docker Compose Deployment

This deployment profile runs the Inventory Allocation Simulator on a Hetzner or DigitalOcean VPS using the GHCR application image, PostgreSQL 16, Redis 7, a one-shot migration container, persistent Docker volumes, and Caddy HTTPS reverse proxy.

## Prerequisites

- A Linux VPS with Docker Engine and the Docker Compose plugin installed.
- DNS `A`/`AAAA` records for the public hostname pointing at the VPS.
- Firewall rules that open ports 80 and 443. Keep port 8000 closed; do not publish the application container port.
- Access to pull the GHCR image if the package is private.

## Environment file

Create `/opt/inventory-allocation-simulator/.env` from `.env.example` and set production values. Do not commit this file.

Required production-oriented values:

```env
APP_ENV=production
APP_HOST=0.0.0.0
APP_PORT=8000
PUBLIC_DOMAIN=inventory.example.com
PUBLIC_BASE_URL=https://inventory.example.com

POSTGRES_DB=inventory_allocation
POSTGRES_USER=inventory
POSTGRES_PASSWORD=replace-with-a-long-random-value
DATABASE_URL=postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
REDIS_URL=redis://redis:6379/0
DUCKDB_PATH=/app/data/backtests.duckdb
UPLOAD_STORAGE_PATH=/app/data/uploads

SESSION_SECRET=replace-with-a-long-random-value
METRICS_TOKEN=replace-with-a-long-random-value
SELF_REGISTRATION_ENABLED=false
```

Optional ecosystem adapter variables (`NOTIFICATION_HUB_URL`, `WORKFLOW_ENGINE_URL`, `DELIVERY_GATEWAY_URL`, and related API keys) can remain disabled or blank unless those adapters are intentionally enabled. Core CSV import, local simulations, local notifications, and recommendation approval work without them.

## Compose services and volumes

`docker-compose.prod.yml` defines:

- `migrate`: pulls the same GHCR image as the app and runs `julia --project scripts/migrate.jl up` after PostgreSQL and Redis are healthy.
- `app`: runs the Genie application on the internal Docker network at `app:8000` after migrations complete.
- `postgres`: PostgreSQL 16 with persistent `postgres-data` volume.
- `redis`: Redis 7 with persistent `redis-data` volume.
- `caddy`: public HTTPS reverse proxy using `config/caddy/Caddyfile` with persistent `caddy-data` and `caddy-config` volumes.
- `app-data`: stores DuckDB backtest data and uploaded/import artifacts at `/app/data`.

Caddy obtains and renews HTTPS certificates automatically for `PUBLIC_DOMAIN` through Let's Encrypt. The application container is reachable only through Caddy; do not publish the application container port.

## First deployment

From `/opt/inventory-allocation-simulator`:

```bash
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up migrate
docker compose -f docker-compose.prod.yml up -d app caddy
```

Then create the first tenant/admin and capture the one-time API key:

```bash
docker compose -f docker-compose.prod.yml exec app julia --project scripts/setup.jl
```

Verify health through the public HTTPS proxy:

```bash
curl -fsS https://inventory.example.com/health
curl -fsS https://inventory.example.com/health/ready
```

Check metrics with the internal token only:

```bash
curl -fsS -H "X-Metrics-Token: $METRICS_TOKEN" https://inventory.example.com/metrics
```

## Upgrade flow

```bash
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up migrate
docker compose -f docker-compose.prod.yml up -d app caddy
```

The app service depends on the migration service completing successfully, so a failed migration prevents the new application container from starting.

## Backup notes

Back up these Docker volumes before upgrades or VPS migration:

- `postgres-data` for relational tenant and planning data.
- `redis-data` for Redis append-only data used by queues/cache.
- `app-data` for DuckDB backtests and uploaded CSV artifacts.
- `caddy-data` and `caddy-config` for Caddy certificates and runtime state.

For PostgreSQL logical backups, run:

```bash
docker compose -f docker-compose.prod.yml exec postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > inventory-allocation.sql
```
