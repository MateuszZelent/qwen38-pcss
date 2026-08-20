#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CORE="${SCRIPT_DIR}/.connect-model-codex-core.sh"
usage() {
  cat <<'EOF'
Uzycie:
  ./scripts/connect-model-codex.sh [gpuXX] [model]
  ./scripts/connect-model-codex.sh --status [model]
  ./scripts/connect-model-codex.sh --stop [model]

Modele (nazwa albo numer):
  1  qwen3.8-27b      port PCSS 8000, port WSL 18000
  2  deepseek-v4-pro  port PCSS 8001, port WSL 18001
  3  kimi-k3          port PCSS 8002, port WSL 18002
  4  ornith-1.5-35b   port PCSS 8003, port WSL 18003
  5  ornith-1.5-397b  port PCSS 8004, port WSL 18004
EOF
}
ACTION=connect
NODE=""
MODEL_INPUT=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --status|--stop) ACTION=${1#--}; MODEL_INPUT=${2:-} ;;
  *) NODE=${1:-}; MODEL_INPUT=${2:-} ;;
esac
if [[ "$ACTION" == connect && -z "$NODE" ]]; then read -r -p "Glowny wezel joba (np. gpu44): " NODE; fi
if [[ -z "$MODEL_INPUT" ]]; then
  printf '\nWybierz model:\n  1) Qwen3.8-27B\n  2) DeepSeek-V4-Pro\n  3) Kimi-K3\n  4) Ornith-1.5-35B-A3B (1xH100)\n  5) Ornith-1.5-397B (4xH100)\n'
  read -r -p "Model [2]: " MODEL_INPUT
  MODEL_INPUT=${MODEL_INPUT:-2}
fi
case "$MODEL_INPUT" in
  1|qwen|qwen3.8-27b) export DEEPSEEK_MODEL_SLUG=qwen3.8-27b DEEPSEEK_REMOTE_PORT=8000 DEEPSEEK_LOCAL_PORT=18000 ;;
  2|deepseek|deepseek-v4-pro) export DEEPSEEK_MODEL_SLUG=deepseek-v4-pro DEEPSEEK_REMOTE_PORT=8001 DEEPSEEK_LOCAL_PORT=18001 ;;
  3|kimi|kimi-k3) export DEEPSEEK_MODEL_SLUG=kimi-k3 DEEPSEEK_REMOTE_PORT=8002 DEEPSEEK_LOCAL_PORT=18002 ;;
  4|ornith|ornith-1.5-35b) export DEEPSEEK_MODEL_SLUG=ornith-1.5-35b DEEPSEEK_REMOTE_PORT=8003 DEEPSEEK_LOCAL_PORT=18003 MODEL_HEALTH_PATH=/api/version UPSTREAM_MODEL_ID='ornith-1.5:35b' ;;
  5|ornith397|ornith-1.5-397b) export DEEPSEEK_MODEL_SLUG=ornith-1.5-397b DEEPSEEK_REMOTE_PORT=8004 DEEPSEEK_LOCAL_PORT=18004 MODEL_HEALTH_PATH=/api/version UPSTREAM_MODEL_ID='ornith-1.5:397b' ;;
  *) printf 'ERROR: nieznany model: %s\n' "$MODEL_INPUT" >&2; usage >&2; exit 2 ;;
esac
export MODEL_TUNNEL_NAME=${DEEPSEEK_MODEL_SLUG//[^a-zA-Z0-9._-]/_}
printf 'Wybrano: %s (PCSS:%s -> WSL:%s)\n' "$DEEPSEEK_MODEL_SLUG" "$DEEPSEEK_REMOTE_PORT" "$DEEPSEEK_LOCAL_PORT"
case "$ACTION" in
  status) exec "$CORE" --status ;;
  stop) exec "$CORE" --stop ;;
  connect) exec "$CORE" "$NODE" ;;
esac
