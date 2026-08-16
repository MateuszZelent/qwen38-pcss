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
#SBATCH --time=1-00:00:00
#SBATCH --chdir=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
#SBATCH --output=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss/deepseek-v4-pro-%j.log

set -Eeuo pipefail

PROJECT_DIR=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
export PCSS_CONFIG="${PROJECT_DIR}/config/deepseek-v4-pro.env"

mapfile -t NODES < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
MASTER_ADDR=${NODES[0]}
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
  "${PROJECT_DIR}/scripts/serve-deepseek-multinode.sh"
