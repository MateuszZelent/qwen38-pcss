#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE=${PCSS_CONFIG:-"${PROJECT_DIR}/config/pcss.env"}

[[ -f "${CONFIG_FILE}" ]] || {
  echo "ERROR: create ${PROJECT_DIR}/config/pcss.env from pcss.env.example" >&2
  exit 2
}
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${SSH_LOGIN:?SSH_LOGIN is required}"
LOCAL=${LOCAL_PORT:-8000}
REMOTE=${REMOTE_PORT:-8000}
MODE=${SSH_TUNNEL_MODE:-proxyjump}

SSH_COMMON=(
  -N -T
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
  -o TCPKeepAlive=yes
)

case "${MODE}" in
  proxyjump)
    : "${SSH_COMPUTE_HOST:?SSH_COMPUTE_HOST is required for proxyjump mode}"
    COMPUTE_USER=${SSH_COMPUTE_USER:-${SSH_LOGIN%%@*}}
    exec ssh "${SSH_COMMON[@]}" \
      -o "ProxyJump=${SSH_LOGIN}" \
      -L "${LOCAL}:127.0.0.1:${REMOTE}" \
      "${COMPUTE_USER}@${SSH_COMPUTE_HOST}"
    ;;
  login-hop)
    : "${SSH_COMPUTE_HOST:?SSH_COMPUTE_HOST is required for login-hop mode}"
    echo "login-hop requires vLLM to listen on an address reachable from the login node." >&2
    echo "Prefer proxyjump mode when direct SSH to the compute node is allowed." >&2
    exec ssh "${SSH_COMMON[@]}" \
      -L "${LOCAL}:${SSH_COMPUTE_HOST}:${REMOTE}" \
      "${SSH_LOGIN}"
    ;;
  login-local)
    exec ssh "${SSH_COMMON[@]}" \
      -L "${LOCAL}:127.0.0.1:${REMOTE}" \
      "${SSH_LOGIN}"
    ;;
  *)
    echo "ERROR: SSH_TUNNEL_MODE must be proxyjump, login-hop, or login-local" >&2
    exit 4
    ;;
esac
