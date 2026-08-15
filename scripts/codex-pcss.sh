#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE=${PCSS_CONFIG:-"${PROJECT_DIR}/config/pcss.env"}

[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true

BASE_URL=${PCSS_VLLM_BASE_URL:-"http://127.0.0.1:${LOCAL_PORT:-8000}/v1"}
export PCSS_VLLM_API_KEY=${PCSS_VLLM_API_KEY:-dummy}

if command -v curl >/dev/null 2>&1; then
  curl --fail --silent --show-error "${BASE_URL}/models" >/dev/null || {
    echo "ERROR: vLLM is not reachable at ${BASE_URL}" >&2
    echo "Start scripts/tunnel-ssh.sh and check the compute-node job." >&2
    exit 5
  }
fi

exec codex "$@"
