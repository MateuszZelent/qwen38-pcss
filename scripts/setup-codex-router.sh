#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
VENDOR_DIR="${PROJECT_DIR}/vendor/codex-shim"
SETTINGS_DIR="${HOME}/.codex-shim"
SETTINGS_PATH="${SETTINGS_DIR}/models.json"
ACTION=${1:-install}
VLLM_BASE_URL=${PCSS_VLLM_BASE_URL:-http://127.0.0.1:18000/v1}
ROUTER_PORT=${CODEX_ROUTER_PORT:-8765}
PYTHON_BIN=${CODEX_ROUTER_PYTHON:-python3}

shim() {
  PYTHONPATH="${VENDOR_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
    "${PYTHON_BIN}" -m codex_shim.cli --settings "${SETTINGS_PATH}" --port "${ROUTER_PORT}" "$@"
}

case "${ACTION}" in
  restore)
    shim disable
    ;;
  status)
    shim doctor
    ;;
  install)
    if ! "${PYTHON_BIN}" -c 'import aiohttp' 2>/dev/null; then
      "${PYTHON_BIN}" -m pip install --user 'aiohttp>=3.9'
    fi
    mkdir -p "${SETTINGS_DIR}"
    sed "s#http://127.0.0.1:18000/v1#${VLLM_BASE_URL%/}#" \
      "${PROJECT_DIR}/config/codex-router-models.json.example" > "${SETTINGS_PATH}"
    shim enable
    shim doctor
    ;;
  *)
    echo "Usage: $0 [install|status|restore]" >&2
    exit 2
    ;;
esac
