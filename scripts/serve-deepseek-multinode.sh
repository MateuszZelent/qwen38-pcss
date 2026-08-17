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

# Tracked sbatch overrides take precedence over an older untracked PCSS config.
MAX_MODEL_LEN=${PCSS_MAX_MODEL_LEN:-${MAX_MODEL_LEN:-1048576}}
MAX_NUM_BATCHED_TOKENS=${PCSS_MAX_NUM_BATCHED_TOKENS:-${MAX_NUM_BATCHED_TOKENS:-2048}}

# The upstream H200 profile performs a 16K-token dummy forward that needs
# roughly 42 GiB of temporary memory. On 94 GiB H100s the weights already use
# about 82 GiB, so qualify the base model with a small profiling batch and no
# speculative draft. This override intentionally also protects older local
# env files that still contain the original H200-oriented values.
if [[ "${H100_SAFE_PROFILE:-1}" == 1 ]]; then
  MAX_NUM_BATCHED_TOKENS=${PCSS_MAX_NUM_BATCHED_TOKENS:-${H100_SAFE_MAX_NUM_BATCHED_TOKENS:-2048}}
  SPECULATIVE_CONFIG=
fi

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
mkdir -p "${MODEL_ROOT}/.hf-cache" "${VLLM_HOME_ROOT}"

NODE_HOST=$(hostname -f 2>/dev/null || hostname)
NODE_IP=${VLLM_HOST_IP:-$(getent ahostsv4 "$(hostname -s)" | awk 'NR == 1 {print $1}')}
[[ -n "${NODE_IP}" ]] || {
  echo "ERROR: cannot determine this node's IPv4 address; set VLLM_HOST_IP" >&2
  exit 5
}

# JIT caches must be node-local. A shared NFS cache lets 16 ranks overwrite
# the same Triton/DeepGEMM artifacts concurrently and can produce stale file
# handles or partially loaded runtimes. Processes on one node may safely share
# the local filesystem cache and its normal locking semantics.
# The sbatch file requests PCSS local NVMe with --constraint=local_ssd and
# --tmp. SLURM exposes the isolated job directory through TMPDIR on each node.
: "${TMPDIR:?PCSS did not provide TMPDIR; submit with --constraint=local_ssd and --tmp}"
[[ -d "${TMPDIR}" && -w "${TMPDIR}" ]] || {
  echo "ERROR: SLURM TMPDIR is not a writable directory: ${TMPDIR}" >&2
  exit 6
}
TMP_FS=$(stat -f -c %T "${TMPDIR}")
case "${TMP_FS}" in
  nfs|nfs4|lustre|gpfs|cifs|smb2)
    echo "ERROR: TMPDIR must be node-local, but ${TMPDIR} uses ${TMP_FS}" >&2
    exit 6
    ;;
esac
LOCAL_JIT_ROOT="${TMPDIR}/vllm-deepseek-${SLURM_JOB_ID}-${SLURM_NODEID}"
mkdir -p \
  "${LOCAL_JIT_ROOT}/flashinfer" \
  "${LOCAL_JIT_ROOT}/torchinductor" \
  "${LOCAL_JIT_ROOT}/triton" \
  "${LOCAL_JIT_ROOT}/tilelang/cache" \
  "${LOCAL_JIT_ROOT}/tilelang/tmp" \
  "${LOCAL_JIT_ROOT}/deep_gemm"
VLLM_ARGS=(
  serve "${MODEL_PATH}"
  --served-model-name "${MODEL_NAME:-deepseek-v4-pro}"
  --dtype "${DTYPE:-auto}"
  --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}"
  --block-size "${BLOCK_SIZE:-256}"
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.95}"
  --max-model-len "${MAX_MODEL_LEN:-1048576}"
  --max-num-seqs "${MAX_NUM_SEQS:-1}"
  --data-parallel-size "${DP_SIZE}"
  --data-parallel-size-local "${GPUS_LOCAL}"
  --data-parallel-address "${MASTER_ADDR}"
  --data-parallel-rpc-port "${DP_RPC_PORT:-13345}"
  --tensor-parallel-size 1
  --trust-remote-code
)

if [[ "${SLURM_NODEID}" == 0 ]]; then
  # Rank zero owns the single internal-LB API endpoint. Passing an explicit
  # start rank (even zero) makes vLLM 0.27 infer hybrid-LB mode, which is
  # incompatible with headless remote nodes.
  VLLM_ARGS+=(
    --api-server-count 1
    --host "${SERVER_HOST:-127.0.0.1}"
    --port "${REMOTE_PORT:-8001}"
  )
else
  VLLM_ARGS+=(--data-parallel-start-rank "${DP_START_RANK}" --headless)
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
echo "memory_profile=h100-safe max_num_batched_tokens=${MAX_NUM_BATCHED_TOKENS:-unset} speculative=$([[ -n "${SPECULATIVE_CONFIG:-}" ]] && echo enabled || echo disabled)" >&2
echo "jit_cache=${LOCAL_JIT_ROOT} filesystem=${TMP_FS} tilelang_cache=${LOCAL_JIT_ROOT}/tilelang/cache" >&2
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
  # Avoid the known H100 cold-cache race in FlashInfer's block-FP8 GEMM
  # selected for M < 32 during DeepSeek-V4-Pro warmup/cudagraph capture.
  # Pure DeepGEMM remains enabled through DG_JIT_CACHE_DIR above.
  export "${prefix}_VLLM_BLOCKSCALE_FP8_GEMM_FLASHINFER=${VLLM_BLOCKSCALE_FP8_GEMM_FLASHINFER:-0}"
  export "${prefix}_TOKENIZERS_PARALLELISM=false"
  export "${prefix}_VLLM_HOST_IP=${NODE_IP}"
  export "${prefix}_NCCL_DEBUG=${NCCL_DEBUG:-INFO}"
  [[ -n "${NCCL_SOCKET_IFNAME:-}" ]] && export "${prefix}_NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME}"
  [[ -n "${NCCL_IB_HCA:-}" ]] && export "${prefix}_NCCL_IB_HCA=${NCCL_IB_HCA}"
  [[ -n "${HF_TOKEN:-}" ]] && export "${prefix}_HF_TOKEN=${HF_TOKEN}"
done

exec "${RUNTIME_BIN}" exec --nv \
  --bind "${MODEL_ROOT}:/models" \
  --bind "${TMPDIR}:${TMPDIR}" \
  "${SIF}" \
  vllm "${VLLM_ARGS[@]}"
