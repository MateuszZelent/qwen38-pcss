#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL=${PCSS_VLLM_BASE_URL:-"http://127.0.0.1:${LOCAL_PORT:-8000}/v1"}

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required" >&2
  exit 127
}

echo "GET ${BASE_URL%/v1}/health"
curl --fail --silent --show-error "${BASE_URL%/v1}/health"
printf '\n\nGET %s/models\n' "${BASE_URL}"
curl --fail --silent --show-error "${BASE_URL}/models"
printf '\n'
