#!/usr/bin/env bash
set -euo pipefail

HOST="${APP_HOST:-127.0.0.1}"
PORT="${APP_PORT:-8124}"
BASE_URL="${PUBLIC_BASE_URL:-http://${HOST}:${PORT}}"
HEALTH_URL="${BASE_URL%/}/health"
TIMEOUT_SECONDS="${E2E_HEALTH_TIMEOUT_SECONDS:-90}"
SERVER_LOG="$(mktemp)"
SERVER_PID=""

cleanup() {
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -f "${SERVER_LOG}"
}
trap cleanup EXIT

julia --project src/Main.jl >"${SERVER_LOG}" 2>&1 &
SERVER_PID="$!"

end_time=$((SECONDS + TIMEOUT_SECONDS))
last_error=""
while (( SECONDS < end_time )); do
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "Server process exited before health check passed." >&2
        cat "${SERVER_LOG}" >&2
        exit 1
    fi

    if response="$(curl -fsS --max-time 2 "${HEALTH_URL}" 2>&1)"; then
        if [[ "${response}" == *'"status":"ok"'* && "${response}" == *'"service":"inventory-allocation-simulator"'* ]]; then
            echo "${response}"
            exit 0
        fi
        echo "Unexpected health response from ${HEALTH_URL}: ${response}" >&2
        exit 1
    else
        last_error="${response}"
    fi

    sleep 1
done

echo "Timed out after ${TIMEOUT_SECONDS}s waiting for ${HEALTH_URL}." >&2
if [[ -n "${last_error}" ]]; then
    echo "Last curl error: ${last_error}" >&2
fi
cat "${SERVER_LOG}" >&2
exit 1
