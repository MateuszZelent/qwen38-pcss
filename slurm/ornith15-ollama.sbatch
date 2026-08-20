#!/usr/bin/env bash
# Ornith-1.5-35B-A3B Q4 on one PCSS H100.
#   sbatch slurm/ornith15-ollama.sbatch

#SBATCH --partition=tesla
#SBATCH --job-name=ornith15
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:h100:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --constraint=local_ssd
#SBATCH --tmp=100G
#SBATCH --time=1-00:00:00
#SBATCH --chdir=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
#SBATCH --output=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss/ornith15-%j.log

set -Eeuo pipefail

PROJECT_DIR=/mnt/storage_3/home/kkingstoun/new_home/git/llm/qwen38-pcss
export PCSS_CONFIG="${PROJECT_DIR}/config/ornith15.env"

echo "job=${SLURM_JOB_ID:-unknown} node=$(hostname) port=8003 gpu=1"
nvidia-smi -L

exec "${PROJECT_DIR}/scripts/serve-ornith15.sh"
