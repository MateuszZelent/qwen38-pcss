#!/usr/bin/env bash
# DeepSeek-V4-Pro-0813 experimental multi-node DP+EP server.
# Submit from the project directory with:
#   sbatch slurm/deepseek-v4-pro-multinode.sbatch
# Override the node count without editing the file:
#   sbatch --nodes=8 slurm/deepseek-v4-pro-multinode.sbatch

#SBATCH --partition=tesla
#SBATCH --job-name=deepseek-v4-pro
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:h100:4
#SBATCH --cpus-per-task=56
#SBATCH --mem=700G
#SBATCH --exclusive
#SBATCH --constraint=local_ssd
#SBATCH --tmp=200G
#SBATCH --time=1-00:00:00
#SBATCH --chdir=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
#SBATCH --output=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss/deepseek-v4-pro-%j.log

set -Eeuo pipefail

PROJECT_DIR=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
export PCSS_CONFIG="${PROJECT_DIR}/config/deepseek-v4-pro.env"
export PCSS_MAX_MODEL_LEN=${PCSS_MAX_MODEL_LEN:-1048576}
export PCSS_MAX_NUM_BATCHED_TOKENS=${PCSS_MAX_NUM_BATCHED_TOKENS:-512}

mapfile -t NODES < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
export PCSS_NETWORK_IFACE=${PCSS_NETWORK_IFACE:-ib0}
MASTER_ADDR=$(ip -4 -o addr show dev "${PCSS_NETWORK_IFACE}" scope global | awk '$4 ~ /^10\.2\./ {sub(/\/.*/, "", $4); print $4; exit}')
[[ -n "${MASTER_ADDR}" ]] || {
  echo "ERROR: cannot determine ${PCSS_NETWORK_IFACE} IPv4 address on batch host" >&2
  exit 7
}
export MASTER_ADDR

echo "job=${SLURM_JOB_ID} nodes=${SLURM_NNODES} gpus=$((SLURM_NNODES * 4))"
echo "nodelist=${NODES[*]} master=${MASTER_ADDR}"
echo "api_node=${MASTER_ADDR} api_port=$(awk -F= '/^REMOTE_PORT=/{print $2}' "${PCSS_CONFIG}")"

# One launcher per node. Each launcher starts four local DP ranks; expert
# weights are sharded across all DP ranks by --enable-expert-parallel.
exec srun --nodes="${SLURM_NNODES}" \
  --ntasks="${SLURM_NNODES}" \
  --ntasks-per-node=1 \
  --kill-on-bad-exit=1 \
  bash "${PROJECT_DIR}/scripts/serve-deepseek-multinode.sh"
