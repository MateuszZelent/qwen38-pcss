#!/usr/bin/env bash
# Kimi-K3 MXFP4 on PCSS: 8 nodes x 4 H100 = 32 DP/Expert-Parallel ranks.
# Submit from the project directory:
#   sbatch slurm/kimi-k3-multinode.sbatch

#SBATCH --partition=tesla
#SBATCH --job-name=kimi-k3
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:h100:4
#SBATCH --cpus-per-task=56
#SBATCH --mem=700G
#SBATCH --exclusive
#SBATCH --constraint=local_ssd
#SBATCH --tmp=500G
#SBATCH --time=1-00:00:00
#SBATCH --chdir=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
#SBATCH --output=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss/kimi-k3-%j.log

set -Eeuo pipefail

PROJECT_DIR=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
export PCSS_CONFIG="${PROJECT_DIR}/config/kimi-k3.env"
export PCSS_NETWORK_IFACE=${PCSS_NETWORK_IFACE:-ib0}

mapfile -t NODES < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
(( SLURM_NNODES >= 8 )) || {
  echo "ERROR: Kimi-K3 on 4xH100 PCSS nodes requires at least 8 nodes (32 GPUs)." >&2
  exit 8
}

MASTER_ADDR=$(ip -4 -o addr show dev "${PCSS_NETWORK_IFACE}" scope global | awk '$4 ~ /^10\.2\./ {sub(/\/.*/, "", $4); print $4; exit}')
[[ -n "${MASTER_ADDR}" ]] || {
  echo "ERROR: cannot determine ${PCSS_NETWORK_IFACE} IPv4 address on batch host" >&2
  exit 7
}
export MASTER_ADDR

DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
DRIVER_MAJOR=${DRIVER_VERSION%%.*}
(( DRIVER_MAJOR >= 580 )) || {
  echo "ERROR: Kimi-K3 CUDA 13 image requires NVIDIA driver r580+, got ${DRIVER_VERSION}" >&2
  exit 9
}
echo "job=${SLURM_JOB_ID} nodes=${SLURM_NNODES} gpus=$((SLURM_NNODES * 4)) driver=${DRIVER_VERSION}"
echo "nodelist=${NODES[*]} master=${MASTER_ADDR}"
echo "api_node=${NODES[0]} api_addr=${MASTER_ADDR} api_port=8002"

exec srun --nodes="${SLURM_NNODES}" \
  --ntasks="${SLURM_NNODES}" \
  --ntasks-per-node=1 \
  --kill-on-bad-exit=1 \
  bash "${PROJECT_DIR}/scripts/serve-kimi-multinode.sh"
