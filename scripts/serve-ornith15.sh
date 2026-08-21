#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE=${PCSS_CONFIG:-"${PROJECT_DIR}/config/ornith15.env"}

[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: create ${PROJECT_DIR}/config/ornith15.env from its example" >&2
  exit 2
}
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${SIF:?SIF is required}"
: "${MODEL_ROOT:?MODEL_ROOT is required}"
: "${MODEL_ID:?MODEL_ID is required}"

RUNTIME_BIN=${CONTAINER_RUNTIME:-}
if [[ -z "${RUNTIME_BIN}" ]]; then
  if command -v apptainer >/dev/null 2>&1; then
    RUNTIME_BIN=apptainer
  elif command -v singularity >/dev/null 2>&1; then
    RUNTIME_BIN=singularity
  else
    echo "ERROR: neither apptainer nor singularity is available in PATH" >&2
    exit 127
  fi
fi
[[ -f "${SIF}" ]] || { echo "ERROR: image not found: ${SIF}" >&2; exit 3; }

LOCAL_TMP=${TMPDIR:-"${MODEL_ROOT}/tmp"}
mkdir -p "${MODEL_ROOT}/models" "${MODEL_ROOT}/home" "${LOCAL_TMP}/ollama"

OLLAMA_ADDR="${SERVER_HOST:-127.0.0.1}:${REMOTE_PORT:-8003}"
for prefix in APPTAINERENV SINGULARITYENV; do
  export "${prefix}_HOME=/ollama/home"
  export "${prefix}_OLLAMA_HOST=${OLLAMA_ADDR}"
  export "${prefix}_OLLAMA_MODELS=/ollama/models"
  export "${prefix}_OLLAMA_CONTEXT_LENGTH=${CONTEXT_LENGTH:-262144}"
  export "${prefix}_OLLAMA_FLASH_ATTENTION=${FLASH_ATTENTION:-1}"
  export "${prefix}_OLLAMA_KV_CACHE_TYPE=${KV_CACHE_TYPE:-q8_0}"
  export "${prefix}_OLLAMA_KEEP_ALIVE=${KEEP_ALIVE:--1}"
  export "${prefix}_OLLAMA_MAX_LOADED_MODELS=${MAX_LOADED_MODELS:-1}"
  export "${prefix}_OLLAMA_NUM_PARALLEL=${NUM_PARALLEL:-1}"
  export "${prefix}_OLLAMA_SCHED_SPREAD=${SCHED_SPREAD:-0}"
  export "${prefix}_OLLAMA_TMPDIR=/tmp/ollama"
done

container=("${RUNTIME_BIN}" exec --nv
  --bind "${MODEL_ROOT}:/ollama"
  --bind "${LOCAL_TMP}/ollama:/tmp/ollama"
  "${SIF}")

cleanup() {
  [[ -n "${server_pid:-}" ]] && kill "${server_pid}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Starting Ollama on ${OLLAMA_ADDR}; model=${MODEL_ID}; context=${CONTEXT_LENGTH:-262144}" >&2
"${container[@]}" ollama serve &
server_pid=$!

for _ in {1..120}; do
  if curl -fsS "http://${OLLAMA_ADDR}/api/version" >/dev/null 2>&1; then
    break
  fi
  kill -0 "${server_pid}" 2>/dev/null || {
    echo "ERROR: Ollama server exited during startup" >&2
    wait "${server_pid}"
  }
  sleep 1
done
curl -fsS "http://${OLLAMA_ADDR}/api/version" || {
  echo "ERROR: Ollama did not become ready within 120 seconds" >&2
  exit 4
}
printf '\n'

if [[ "${PULL_MODEL:-1}" == 1 ]]; then
  "${container[@]}" ollama pull "${MODEL_ID}"
fi
"${container[@]}" ollama show "${MODEL_ID}" >/dev/null

# Warm-load the model and make GPU placement visible in the job log.
curl -fsS -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"keep_alive\":-1}" \
  "http://${OLLAMA_ADDR}/api/generate" >/dev/null
"${container[@]}" ollama ps
echo "Ornith API ready: http://${OLLAMA_ADDR}/v1" >&2

wait "${server_pid}"
