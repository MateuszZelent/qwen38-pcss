#!/usr/bin/env bash
# Qwen3.8-27B server on one H100. Submit from the project tree with:
#   sbatch slurm/qwen38-vllm.sbatch

# PCSS exposes H100 nodes in the tesla partition. Use proxima instead only if
# your local allocation policy requires it.
#SBATCH --partition=tesla
#SBATCH --job-name=qwen38-vllm
#SBATCH --gres=gpu:h100:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=96G
#SBATCH --time=1-00:00:00
#SBATCH --chdir=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
#SBATCH --output=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss/qwen38-vllm-%j.log

set -Eeuo pipefail

PROJECT_DIR=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
export PCSS_CONFIG="${PROJECT_DIR}/config/pcss.env"

echo "job=${SLURM_JOB_ID:-unknown}"
echo "node=$(hostname)"
echo "port=$(awk -F= '/^REMOTE_PORT=/{print $2}' "${PCSS_CONFIG}")"
nvidia-smi -L

exec "${PROJECT_DIR}/scripts/serve-local.sh"
