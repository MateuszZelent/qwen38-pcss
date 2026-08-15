#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE=${PCSS_CONFIG:-"${PROJECT_DIR}/config/pcss.env"}

[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: create ${PROJECT_DIR}/config/pcss.env from pcss.env.example" >&2
  exit 2
}
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${SIF:?SIF is required}"
: "${MODEL_ROOT:?MODEL_ROOT is required}"
: "${MODEL_SUBDIR:?MODEL_SUBDIR is required}"

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
[[ -f "${SIF}" ]] || {
  echo "ERROR: image not found: ${SIF}" >&2
  exit 3
}
[[ -d "${MODEL_ROOT}/${MODEL_SUBDIR}" ]] || {
  echo "ERROR: model directory not found: ${MODEL_ROOT}/${MODEL_SUBDIR}" >&2
  exit 4
}

# Keep JIT/compiler caches on the project storage. The compute-node home path
# may not be visible inside the Apptainer namespace; FlashInfer otherwise
# defaults to ~/.cache/flashinfer and can fail during model inspection.
VLLM_CACHE_ROOT="${MODEL_ROOT}/.vllm-cache"
VLLM_HOME_ROOT="${MODEL_ROOT}/.vllm-home"
mkdir -p "${MODEL_ROOT}/.hf-cache" "${VLLM_CACHE_ROOT}" "${VLLM_HOME_ROOT}"

MODEL_PATH="/models/${MODEL_SUBDIR}"
HOST=${SERVER_HOST:-127.0.0.1}
PORT=${REMOTE_PORT:-8000}
MODEL_ALIAS=${MODEL_NAME:-qwen3.8-27b}

VLLM_ARGS=(
  serve "${MODEL_PATH}"
  --host "${HOST}"
  --port "${PORT}"
  --served-model-name "${MODEL_ALIAS}"
  --dtype "${DTYPE:-bfloat16}"
  --tensor-parallel-size "${TENSOR_PARALLEL_SIZE:-1}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.90}"
  --max-model-len "${MAX_MODEL_LEN:-32768}"
  --max-num-seqs "${MAX_NUM_SEQS:-1}"
  --trust-remote-code
)

if [[ "${ENABLE_AUTO_TOOL_CHOICE:-1}" == 1 ]]; then
  VLLM_ARGS+=(--enable-auto-tool-choice)
  [[ -n "${TOOL_CALL_PARSER:-}" ]] && VLLM_ARGS+=(--tool-call-parser "${TOOL_CALL_PARSER}")
fi
[[ -n "${REASONING_PARSER:-}" ]] && VLLM_ARGS+=(--reasoning-parser "${REASONING_PARSER}")
[[ -n "${KV_CACHE_DTYPE:-}" ]] && VLLM_ARGS+=(--kv-cache-dtype "${KV_CACHE_DTYPE}")
[[ "${ENABLE_PREFIX_CACHING:-0}" == 1 ]] && VLLM_ARGS+=(--enable-prefix-caching)
[[ "${ENABLE_CHUNKED_PREFILL:-0}" == 1 ]] && VLLM_ARGS+=(--enable-chunked-prefill)
[[ -n "${MAX_NUM_BATCHED_TOKENS:-}" ]] && VLLM_ARGS+=(--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}")

echo "Starting ${MODEL_ALIAS} on ${HOST}:${PORT}" >&2
printf 'vLLM arguments:' >&2
printf ' %q' "${VLLM_ARGS[@]}" >&2
printf '\n' >&2

# Support both Apptainer and the legacy Singularity environment prefixes.
export APPTAINERENV_HF_HOME=/models/.hf-cache
export SINGULARITYENV_HF_HOME=/models/.hf-cache
export APPTAINERENV_HF_HUB_DISABLE_TELEMETRY=1
export SINGULARITYENV_HF_HUB_DISABLE_TELEMETRY=1
export APPTAINERENV_TOKENIZERS_PARALLELISM=false
export SINGULARITYENV_TOKENIZERS_PARALLELISM=false
export APPTAINERENV_HOME=/models/.vllm-home
export SINGULARITYENV_HOME=/models/.vllm-home
export APPTAINERENV_XDG_CACHE_HOME=/models/.vllm-cache
export SINGULARITYENV_XDG_CACHE_HOME=/models/.vllm-cache
export APPTAINERENV_FLASHINFER_WORKSPACE_BASE=/models/.vllm-cache
export SINGULARITYENV_FLASHINFER_WORKSPACE_BASE=/models/.vllm-cache
export APPTAINERENV_TORCHINDUCTOR_CACHE_DIR=/models/.vllm-cache/torchinductor
export SINGULARITYENV_TORCHINDUCTOR_CACHE_DIR=/models/.vllm-cache/torchinductor
export APPTAINERENV_TRITON_CACHE_DIR=/models/.vllm-cache/triton
export SINGULARITYENV_TRITON_CACHE_DIR=/models/.vllm-cache/triton

exec "${RUNTIME_BIN}" exec --nv \
  --bind "${MODEL_ROOT}:/models" \
  "${SIF}" \
  vllm "${VLLM_ARGS[@]}"
