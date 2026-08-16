#!/usr/bin/env bash
set -Eeuo pipefail

# Tunnel both PCSS models. Hosts may differ between Slurm jobs:
#   bash scripts/tunnel-models-ssh.sh QWEN_NODE DEEPSEEK_NODE
# If both API servers happen to run on the same node, one SSH connection is
# used for both forwards.

QWEN_HOST=${1:-${QWEN_COMPUTE_HOST:-}}
DEEPSEEK_HOST=${2:-${DEEPSEEK_COMPUTE_HOST:-}}
SSH_LOGIN=${PCSS_SSH_LOGIN:-kkingstoun@eagle.man.poznan.pl}
COMPUTE_USER=${PCSS_COMPUTE_USER:-${SSH_LOGIN%%@*}}
QWEN_LOCAL_PORT=${QWEN_LOCAL_PORT:-18000}
QWEN_REMOTE_PORT=${QWEN_REMOTE_PORT:-8000}
DEEPSEEK_LOCAL_PORT=${DEEPSEEK_LOCAL_PORT:-18001}
DEEPSEEK_REMOTE_PORT=${DEEPSEEK_REMOTE_PORT:-8001}

[[ -n "${QWEN_HOST}" ]] || { echo "ERROR: QWEN_NODE is required" >&2; exit 2; }
[[ -n "${DEEPSEEK_HOST}" ]] || { echo "ERROR: DEEPSEEK_NODE is required" >&2; exit 2; }

SSH_COMMON=(
  -N -T
  -o ExitOnForwardFailure=yes
  -o GSSAPIAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o TCPKeepAlive=yes
  -o "ProxyJump=${SSH_LOGIN}"
)

if [[ "${QWEN_HOST}" == "${DEEPSEEK_HOST}" ]]; then
  echo "Tunneling Qwen ${QWEN_HOST}:${QWEN_REMOTE_PORT} -> 127.0.0.1:${QWEN_LOCAL_PORT}" >&2
  echo "Tunneling DeepSeek ${DEEPSEEK_HOST}:${DEEPSEEK_REMOTE_PORT} -> 127.0.0.1:${DEEPSEEK_LOCAL_PORT}" >&2
  exec ssh "${SSH_COMMON[@]}" \
    -L "127.0.0.1:${QWEN_LOCAL_PORT}:127.0.0.1:${QWEN_REMOTE_PORT}" \
    -L "127.0.0.1:${DEEPSEEK_LOCAL_PORT}:127.0.0.1:${DEEPSEEK_REMOTE_PORT}" \
    "${COMPUTE_USER}@${QWEN_HOST}"
fi

pids=()
cleanup() {
  if ((${#pids[@]})); then
    kill "${pids[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "Tunneling Qwen ${QWEN_HOST}:${QWEN_REMOTE_PORT} -> 127.0.0.1:${QWEN_LOCAL_PORT}" >&2
ssh "${SSH_COMMON[@]}" \
  -L "127.0.0.1:${QWEN_LOCAL_PORT}:127.0.0.1:${QWEN_REMOTE_PORT}" \
  "${COMPUTE_USER}@${QWEN_HOST}" &
pids+=("$!")

echo "Tunneling DeepSeek ${DEEPSEEK_HOST}:${DEEPSEEK_REMOTE_PORT} -> 127.0.0.1:${DEEPSEEK_LOCAL_PORT}" >&2
ssh "${SSH_COMMON[@]}" \
  -L "127.0.0.1:${DEEPSEEK_LOCAL_PORT}:127.0.0.1:${DEEPSEEK_REMOTE_PORT}" \
  "${COMPUTE_USER}@${DEEPSEEK_HOST}" &
pids+=("$!")

wait "${pids[@]}"
