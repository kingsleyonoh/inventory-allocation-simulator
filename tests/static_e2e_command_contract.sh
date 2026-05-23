#!/usr/bin/env bash
set -euo pipefail

python - <<'PY'
from pathlib import Path
import json
import sys

errors = []
result_path = Path('.yolo/batch-results/batch-002-implement.json')
script_path = Path('scripts/e2e_health_check.sh')

if not result_path.exists():
    errors.append('missing batch 002 implement machine result')
else:
    result = json.loads(result_path.read_text(encoding='utf-8'))
    command = result.get('tests', {}).get('e2e', {}).get('command', '')
    if 'scripts/e2e_health_check.sh' not in command:
        errors.append('batch 002 E2E command must invoke scripts/e2e_health_check.sh instead of curling immediately after backgrounding the server')
    if 'julia --project src/Main.jl & curl' in command:
        errors.append('batch 002 E2E command still contains the racy `julia --project src/Main.jl & curl` pattern')
    if 'APP_PORT=' not in command or 'PUBLIC_BASE_URL=' not in command:
        errors.append('batch 002 E2E command must document the host/port/base URL used by the rerunnable gate')

if not script_path.exists():
    errors.append('missing scripts/e2e_health_check.sh readiness helper')
else:
    script = script_path.read_text(encoding='utf-8')
    required_tokens = [
        'trap cleanup EXIT',
        'julia --project src/Main.jl',
        'curl -fsS',
        'E2E_HEALTH_TIMEOUT_SECONDS',
        'SERVER_PID',
        'kill "${SERVER_PID}"',
    ]
    for token in required_tokens:
        if token not in script:
            errors.append(f'scripts/e2e_health_check.sh missing {token}')

if errors:
    print('E2E COMMAND CONTRACT FAIL')
    for error in errors:
        print(f'- {error}')
    sys.exit(1)
print('E2E COMMAND CONTRACT PASS')
PY
