#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
VENDOR_DIR="${PROJECT_DIR}/vendor/codex-shim"
SETTINGS_DIR="${HOME}/.codex-shim"
SETTINGS_PATH="${SETTINGS_DIR}/models.json"
ACTION=${1:-install}
QWEN_BASE_URL=${PCSS_VLLM_BASE_URL:-http://127.0.0.1:18000/v1}
DEEPSEEK_BASE_URL=${PCSS_DEEPSEEK_BASE_URL:-http://127.0.0.1:18001/v1}
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
    "${PYTHON_BIN}" - \
      "${PROJECT_DIR}/config/codex-router-models.json.example" \
      "${SETTINGS_PATH}" \
      "${QWEN_BASE_URL%/}" \
      "${DEEPSEEK_BASE_URL%/}" <<'PY'
import json
import sys

template, output, qwen_url, deepseek_url = sys.argv[1:]
with open(template, encoding="utf-8") as handle:
    settings = json.load(handle)
urls = {
    "qwen3.8-27b": qwen_url,
    "deepseek-v4-pro": deepseek_url,
}
for model in settings["models"]:
    if model.get("slug") in urls:
        model["base_url"] = urls[model["slug"]]
with open(output, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY
    shim enable
    shim doctor
    ;;
  *)
    echo "Usage: $0 [install|status|restore]" >&2
    exit 2
    ;;
esac
