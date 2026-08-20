#!/usr/bin/env bash
# Ornith-1.5-397B quantized Ollama build on four PCSS H100 GPUs.
#   sbatch slurm/ornith15-397b-ollama.sbatch

#SBATCH --partition=tesla
#SBATCH --job-name=ornith15-397b
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:h100:4
#SBATCH --cpus-per-task=32
#SBATCH --mem=256G
#SBATCH --constraint=local_ssd
#SBATCH --tmp=200G
#SBATCH --time=1-00:00:00
#SBATCH --chdir=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
#SBATCH --output=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss/ornith15-397b-%j.log

set -Eeuo pipefail

PROJECT_DIR=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
export PCSS_CONFIG="${PROJECT_DIR}/config/ornith15-397b.env"

echo "job=${SLURM_JOB_ID:-unknown} node=$(hostname) port=8004 gpus=4"
nvidia-smi -L

exec "${PROJECT_DIR}/scripts/serve-ornith15.sh"
