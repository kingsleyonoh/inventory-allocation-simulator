#!/usr/bin/env bash
set -euo pipefail

python - <<'PY'
from pathlib import Path
import re
import sys

errors = []

def require(path, description):
    p = Path(path)
    if not p.exists():
        errors.append(f"missing {description}: {path}")
    return p

project = require("Project.toml", "Julia project manifest")
if project.exists():
    text = project.read_text(encoding="utf-8")
    for dep in ["Genie", "HTTP", "LibPQ", "Redis", "DuckDB", "JuMP", "HiGHS", "StatsBase", "Distributions", "JSON3"]:
        if not re.search(rf"^{dep}\s*=", text, re.MULTILINE):
            errors.append(f"Project.toml missing dependency {dep}")
    if "InventoryAllocationSimulator" not in text:
        errors.append("Project.toml missing project name InventoryAllocationSimulator")

for path in [
    "src/InventoryAllocationSimulator.jl", "src/Main.jl", "config/routes.jl", "migrations", "scripts",
    "src/db", "src/tenant", "src/imports", "src/planning", "src/solver",
    "src/recommendations", "src/notifications", "src/jobs", "src/integrations",
    "src/events", "src/web/controllers", "src/web/views", "src/web/components",
    "src/observability", "data", "data/uploads"
]:
    require(path, "required project scaffold path")

package_entry = Path("src/InventoryAllocationSimulator.jl")
if package_entry.exists():
    text = package_entry.read_text(encoding="utf-8")
    for token in ["module InventoryAllocationSimulator", "function run_server!", "include(\"../config/routes.jl\")"]:
        if token not in text:
            errors.append(f"src/InventoryAllocationSimulator.jl missing {token}")

main = Path("src/Main.jl")
if main.exists() and "InventoryAllocationSimulator.main()" not in main.read_text(encoding="utf-8"):
    errors.append("src/Main.jl missing InventoryAllocationSimulator.main() script entrypoint")

routes = Path("config/routes.jl")
if routes.exists():
    text = routes.read_text(encoding="utf-8")
    if "register_routes!" not in text:
        errors.append("config/routes.jl missing register_routes!")
    if "/health" not in text:
        errors.append("config/routes.jl missing health route scaffold")

compose = require("docker-compose.yml", "local Docker Compose file")
if compose.exists():
    text = compose.read_text(encoding="utf-8")
    for token in ["postgres:16", "redis:7", "healthcheck:", "pg_isready", "redis-cli ping", "${POSTGRES_PASSWORD"]:
        if token not in text:
            errors.append(f"docker-compose.yml missing {token}")

env = require(".env.example", "environment placeholder file")
if env.exists():
    text = env.read_text(encoding="utf-8")
    for token in ["POSTGRES_PASSWORD=your-password-here", "DATABASE_URL=postgres://${POSTGRES_USER", "REDIS_URL=redis://localhost:6379/0", "DUCKDB_PATH=./data/backtests.duckdb", "UPLOAD_STORAGE_PATH=./data/uploads", "SESSION_SECRET=your-session-secret-here"]:
        if token not in text:
            errors.append(f".env.example missing {token}")
    for forbidden in ["SESSION_SECRET=xxxxx", "NOTIFICATION_HUB_API_KEY=xxxxx", "WORKFLOW_ENGINE_API_KEY=xxxxx", "DELIVERY_GATEWAY_API_KEY=xxxxx"]:
        if forbidden in text:
            errors.append(f".env.example still has weak placeholder {forbidden}")

if errors:
    print("SETUP CONTRACT FAIL")
    for err in errors:
        print(f"- {err}")
    sys.exit(1)
print("SETUP CONTRACT PASS")
PY
