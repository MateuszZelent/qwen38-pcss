#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE=${PCSS_CONFIG:-"${PROJECT_DIR}/config/deepseek-v4-pro.env"}

[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: create ${PROJECT_DIR}/config/deepseek-v4-pro.env from its example" >&2
  exit 2
}
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${SLURM_NNODES:?run this launcher through the multi-node Slurm job}"
: "${SLURM_NODEID:?SLURM_NODEID is required}"
: "${MASTER_ADDR:?MASTER_ADDR is required}"
: "${SIF:?SIF is required}"
: "${MODEL_ROOT:?MODEL_ROOT is required}"
: "${MODEL_SUBDIR:?MODEL_SUBDIR is required}"

GPUS_LOCAL=${GPUS_PER_NODE:-4}
DP_SIZE=$((SLURM_NNODES * GPUS_LOCAL))
DP_START_RANK=$((SLURM_NODEID * GPUS_LOCAL))
MODEL_PATH="/models/${MODEL_SUBDIR}"
VLLM_CACHE_ROOT="${MODEL_ROOT}/.vllm-cache"
VLLM_HOME_ROOT="${MODEL_ROOT}/.vllm-home"

if command -v apptainer >/dev/null 2>&1; then
  RUNTIME_BIN=${CONTAINER_RUNTIME:-apptainer}
elif command -v singularity >/dev/null 2>&1; then
  RUNTIME_BIN=${CONTAINER_RUNTIME:-singularity}
else
  echo "ERROR: neither apptainer nor singularity is available" >&2
  exit 127
fi

[[ -f "${SIF}" ]] || { echo "ERROR: image not found: ${SIF}" >&2; exit 3; }
[[ -d "${MODEL_ROOT}/${MODEL_SUBDIR}" ]] || {
  echo "ERROR: model directory not found: ${MODEL_ROOT}/${MODEL_SUBDIR}" >&2
  exit 4
}
mkdir -p "${MODEL_ROOT}/.hf-cache" "${VLLM_CACHE_ROOT}" "${VLLM_HOME_ROOT}"

NODE_HOST=$(hostname -f 2>/dev/null || hostname)
NODE_IP=${VLLM_HOST_IP:-$(getent ahostsv4 "$(hostname -s)" | awk 'NR == 1 {print $1}')}
[[ -n "${NODE_IP}" ]] || {
  echo "ERROR: cannot determine this node's IPv4 address; set VLLM_HOST_IP" >&2
  exit 5
}
VLLM_ARGS=(
  serve "${MODEL_PATH}"
  --served-model-name "${MODEL_NAME:-deepseek-v4-pro}"
  --dtype "${DTYPE:-auto}"
  --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}"
  --block-size "${BLOCK_SIZE:-256}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.95}"
  --max-model-len "${MAX_MODEL_LEN:-200000}"
  --max-num-seqs "${MAX_NUM_SEQS:-1}"
  --data-parallel-size "${DP_SIZE}"
  --data-parallel-size-local "${GPUS_LOCAL}"
  --data-parallel-start-rank "${DP_START_RANK}"
  --data-parallel-address "${MASTER_ADDR}"
  --data-parallel-rpc-port "${DP_RPC_PORT:-13345}"
  --tensor-parallel-size 1
  --trust-remote-code
)

if [[ "${SLURM_NODEID}" == 0 ]]; then
  VLLM_ARGS+=(--host "${SERVER_HOST:-127.0.0.1}" --port "${REMOTE_PORT:-8001}")
else
  VLLM_ARGS+=(--headless)
fi
[[ "${ENABLE_EXPERT_PARALLEL:-1}" == 1 ]] && VLLM_ARGS+=(--enable-expert-parallel)
[[ "${ENABLE_AUTO_TOOL_CHOICE:-1}" == 1 ]] && VLLM_ARGS+=(--enable-auto-tool-choice)
[[ -n "${TOKENIZER_MODE:-}" ]] && VLLM_ARGS+=(--tokenizer-mode "${TOKENIZER_MODE}")
[[ -n "${TOOL_CALL_PARSER:-}" ]] && VLLM_ARGS+=(--tool-call-parser "${TOOL_CALL_PARSER}")
[[ -n "${REASONING_PARSER:-}" ]] && VLLM_ARGS+=(--reasoning-parser "${REASONING_PARSER}")
[[ -n "${MAX_NUM_BATCHED_TOKENS:-}" ]] && VLLM_ARGS+=(--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}")
[[ -n "${SPECULATIVE_CONFIG:-}" ]] && VLLM_ARGS+=(--speculative-config "${SPECULATIVE_CONFIG}")
[[ -n "${COMPILATION_CONFIG:-}" ]] && VLLM_ARGS+=(--compilation-config "${COMPILATION_CONFIG}")
[[ "${DISABLE_FLASHINFER_AUTOTUNE:-1}" == 1 ]] && VLLM_ARGS+=(--no-enable-flashinfer-autotune)

echo "node_id=${SLURM_NODEID} host=${NODE_HOST} ip=${NODE_IP} master=${MASTER_ADDR} dp=${DP_SIZE} local_dp=${GPUS_LOCAL} start_rank=${DP_START_RANK}" >&2
nvidia-smi -L

for prefix in APPTAINERENV SINGULARITYENV; do
  export "${prefix}_HF_HOME=/models/.hf-cache"
  export "${prefix}_XDG_CACHE_HOME=/models/.vllm-cache"
  export "${prefix}_FLASHINFER_WORKSPACE_BASE=/models/.vllm-cache"
  export "${prefix}_TORCHINDUCTOR_CACHE_DIR=/models/.vllm-cache/torchinductor"
  export "${prefix}_TRITON_CACHE_DIR=/models/.vllm-cache/triton"
  export "${prefix}_TOKENIZERS_PARALLELISM=false"
  export "${prefix}_VLLM_HOST_IP=${NODE_IP}"
  export "${prefix}_NCCL_DEBUG=${NCCL_DEBUG:-INFO}"
  [[ -n "${NCCL_SOCKET_IFNAME:-}" ]] && export "${prefix}_NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME}"
  [[ -n "${NCCL_IB_HCA:-}" ]] && export "${prefix}_NCCL_IB_HCA=${NCCL_IB_HCA}"
  [[ -n "${HF_TOKEN:-}" ]] && export "${prefix}_HF_TOKEN=${HF_TOKEN}"
done

exec "${RUNTIME_BIN}" exec --nv \
  --bind "${MODEL_ROOT}:/models" \
  --bind /dev/shm:/dev/shm \
  "${SIF}" \
  vllm "${VLLM_ARGS[@]}"
