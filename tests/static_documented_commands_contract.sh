#!/usr/bin/env bash
set -euo pipefail

python - <<'PY'
from pathlib import Path
import sys
import tomllib

expected_command = "julia --project -e 'using Aqua, InventoryAllocationSimulator; Aqua.test_all(InventoryAllocationSimulator; stale_deps=false)'"
project = tomllib.loads(Path("Project.toml").read_text(encoding="utf-8"))
context = Path(".agent/rules/CODEBASE_CONTEXT.md").read_text(encoding="utf-8")
deps = project.get("deps", {})
errors = []
if "Aqua" not in deps:
    errors.append("Project.toml must include Aqua in [deps] so the documented Aqua command can load in the active project")
if "Aqua" not in project.get("compat", {}):
    errors.append("Project.toml must keep an Aqua compat bound")
if expected_command not in context:
    errors.append("CODEBASE_CONTEXT.md must document the runnable Aqua command with the project module argument")
if errors:
    print("DOCUMENTED COMMAND CONTRACT FAIL")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)
print("DOCUMENTED COMMAND CONTRACT STATIC PASS")
PY

julia --project -e 'using Aqua, InventoryAllocationSimulator; Aqua.test_all(InventoryAllocationSimulator; stale_deps=false)'
