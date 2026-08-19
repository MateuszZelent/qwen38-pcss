#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE=${PCSS_CONFIG:-"${PROJECT_DIR}/config/kimi-k3.env"}

[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: create config/kimi-k3.env from config/kimi-k3.env.example" >&2
  exit 2
}
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${SLURM_NNODES:?run through slurm/kimi-k3-multinode.sbatch}"
: "${SLURM_NODEID:?SLURM_NODEID is required}"
: "${MASTER_ADDR:?MASTER_ADDR is required}"
: "${SIF:?SIF is required}"
: "${MODEL_ROOT:?MODEL_ROOT is required}"
: "${MODEL_SUBDIR:?MODEL_SUBDIR is required}"

GPUS_LOCAL=${GPUS_PER_NODE:-4}
MIN_REQUIRED_NODES=${MIN_NODES:-8}
(( SLURM_NNODES >= MIN_REQUIRED_NODES )) || {
  echo "ERROR: need at least ${MIN_REQUIRED_NODES} nodes, got ${SLURM_NNODES}" >&2
  exit 8
}
DP_SIZE=$((SLURM_NNODES * GPUS_LOCAL))
DP_START_RANK=$((SLURM_NODEID * GPUS_LOCAL))
MODEL_PATH="/models/${MODEL_SUBDIR}"

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
: "${TMPDIR:?PCSS TMPDIR missing; submit with --constraint=local_ssd and --tmp}"
[[ -d "${TMPDIR}" && -w "${TMPDIR}" ]] || {
  echo "ERROR: TMPDIR is not writable: ${TMPDIR}" >&2
  exit 6
}
TMP_FS=$(stat -f -c %T "${TMPDIR}")
case "${TMP_FS}" in
  nfs|nfs4|lustre|gpfs|cifs|smb2)
    echo "ERROR: TMPDIR must be node-local, got ${TMP_FS}" >&2
    exit 6 ;;
esac

NETWORK_IFACE=${PCSS_NETWORK_IFACE:-${NETWORK_IFACE:-ib0}}
NODE_IP=${VLLM_HOST_IP:-$(ip -4 -o addr show dev "${NETWORK_IFACE}" scope global | awk '$4 ~ /^10\.2\./ {sub(/\/.*/, "", $4); print $4; exit}')}
[[ -n "${NODE_IP}" ]] || { echo "ERROR: no IPv4 on ${NETWORK_IFACE}" >&2; exit 5; }

LOCAL_JIT_ROOT="${TMPDIR}/vllm-kimi-k3-${SLURM_JOB_ID}-${SLURM_NODEID}"
mkdir -p "${MODEL_ROOT}/.hf-cache" \
  "${LOCAL_JIT_ROOT}/flashinfer" "${LOCAL_JIT_ROOT}/torchinductor" \
  "${LOCAL_JIT_ROOT}/triton" "${LOCAL_JIT_ROOT}/tilelang/cache" \
  "${LOCAL_JIT_ROOT}/tilelang/tmp" "${LOCAL_JIT_ROOT}/deep_gemm"

VLLM_ARGS=(
  serve "${MODEL_PATH}"
  --served-model-name "${MODEL_NAME:-kimi-k3}"
  --dtype "${DTYPE:-auto}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.97}"
  --max-model-len "${MAX_MODEL_LEN:-32768}"
  --max-num-seqs "${MAX_NUM_SEQS:-5}"
  --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-4096}"
  --data-parallel-size "${DP_SIZE}"
  --data-parallel-size-local "${GPUS_LOCAL}"
  --data-parallel-address "${MASTER_ADDR}"
  --data-parallel-rpc-port "${DP_RPC_PORT:-13346}"
  --tensor-parallel-size 1
  --trust-remote-code
)

if [[ "${SLURM_NODEID}" == 0 ]]; then
  VLLM_ARGS+=(--api-server-count 1 --host "${SERVER_HOST:-127.0.0.1}" --port "${REMOTE_PORT:-8002}")
else
  VLLM_ARGS+=(--data-parallel-start-rank "${DP_START_RANK}" --headless)
fi

[[ "${ENABLE_EXPERT_PARALLEL:-1}" == 1 ]] && VLLM_ARGS+=(--enable-expert-parallel)
[[ -n "${ALL2ALL_BACKEND:-}" ]] && VLLM_ARGS+=(--all2all-backend "${ALL2ALL_BACKEND}")
[[ "${ENABLE_AUTO_TOOL_CHOICE:-1}" == 1 ]] && VLLM_ARGS+=(--enable-auto-tool-choice)
[[ -n "${TOOL_CALL_PARSER:-}" ]] && VLLM_ARGS+=(--tool-call-parser "${TOOL_CALL_PARSER}")
[[ -n "${REASONING_PARSER:-}" ]] && VLLM_ARGS+=(--reasoning-parser "${REASONING_PARSER}")
[[ "${LANGUAGE_MODEL_ONLY:-1}" == 1 ]] && VLLM_ARGS+=(--language-model-only)
[[ -n "${MOE_BACKEND:-}" ]] && VLLM_ARGS+=(--moe-backend "${MOE_BACKEND}")
[[ -n "${ATTENTION_BACKEND:-}" ]] && VLLM_ARGS+=(--attention-backend "${ATTENTION_BACKEND}")
[[ "${DISABLE_CUSTOM_ALL_REDUCE:-1}" == 1 ]] && VLLM_ARGS+=(--disable-custom-all-reduce)
[[ "${DISABLE_FLASHINFER_AUTOTUNE:-1}" == 1 ]] && VLLM_ARGS+=(--no-enable-flashinfer-autotune)
[[ -n "${SPECULATIVE_CONFIG:-}" ]] && VLLM_ARGS+=(--speculative-config "${SPECULATIVE_CONFIG}")

echo "node_id=${SLURM_NODEID} host=$(hostname) ip=${NODE_IP} master=${MASTER_ADDR} dp=${DP_SIZE} start_rank=${DP_START_RANK}" >&2
echo "model=${MODEL_PATH} context=${MAX_MODEL_LEN:-32768} jit=${LOCAL_JIT_ROOT} fs=${TMP_FS}" >&2
nvidia-smi -L

for prefix in APPTAINERENV SINGULARITYENV; do
  export "${prefix}_HF_HOME=/models/.hf-cache"
  export "${prefix}_XDG_CACHE_HOME=${LOCAL_JIT_ROOT}"
  export "${prefix}_VLLM_CACHE_ROOT=${LOCAL_JIT_ROOT}"
  export "${prefix}_FLASHINFER_WORKSPACE_BASE=${LOCAL_JIT_ROOT}/flashinfer"
  export "${prefix}_TORCHINDUCTOR_CACHE_DIR=${LOCAL_JIT_ROOT}/torchinductor"
  export "${prefix}_TRITON_CACHE_DIR=${LOCAL_JIT_ROOT}/triton"
  export "${prefix}_TILELANG_CACHE_DIR=${LOCAL_JIT_ROOT}/tilelang/cache"
  export "${prefix}_TILELANG_TMP_DIR=${LOCAL_JIT_ROOT}/tilelang/tmp"
  export "${prefix}_DG_JIT_CACHE_DIR=${LOCAL_JIT_ROOT}/deep_gemm"
  export "${prefix}_TOKENIZERS_PARALLELISM=false"
  export "${prefix}_VLLM_HOST_IP=${NODE_IP}"
  export "${prefix}_GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-${NETWORK_IFACE}}"
  export "${prefix}_NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME:-${NETWORK_IFACE}}"
  export "${prefix}_NCCL_DEBUG=${NCCL_DEBUG:-INFO}"
  export "${prefix}_NCCL_DMABUF_ENABLE=${NCCL_DMABUF_ENABLE:-0}"
  export "${prefix}_VLLM_ENGINE_READY_TIMEOUT_S=${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"
  export "${prefix}_VLLM_USE_V2_MODEL_RUNNER=${VLLM_USE_V2_MODEL_RUNNER:-1}"
  export "${prefix}_VLLM_USE_RUST_FRONTEND=${VLLM_USE_RUST_FRONTEND:-1}"
  export "${prefix}_PYTORCH_CUDA_ALLOC_CONF=${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
  [[ -n "${NCCL_IB_HCA:-}" ]] && export "${prefix}_NCCL_IB_HCA=${NCCL_IB_HCA}"
  [[ -n "${HF_TOKEN:-}" ]] && export "${prefix}_HF_TOKEN=${HF_TOKEN}"
done

exec "${RUNTIME_BIN}" exec --nv \
  --bind "${MODEL_ROOT}:/models" \
  --bind "${TMPDIR}:${TMPDIR}" \
  "${SIF}" \
  vllm "${VLLM_ARGS[@]}"
