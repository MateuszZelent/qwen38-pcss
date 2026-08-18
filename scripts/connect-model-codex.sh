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
  printf '\nWybierz model:\n  1) Qwen3.8-27B\n  2) DeepSeek-V4-Pro\n  3) Kimi-K3\n'
  read -r -p "Model [2]: " MODEL_INPUT
  MODEL_INPUT=${MODEL_INPUT:-2}
fi
case "$MODEL_INPUT" in
  1|qwen|qwen3.8-27b) export DEEPSEEK_MODEL_SLUG=qwen3.8-27b DEEPSEEK_REMOTE_PORT=8000 DEEPSEEK_LOCAL_PORT=18000 ;;
  2|deepseek|deepseek-v4-pro) export DEEPSEEK_MODEL_SLUG=deepseek-v4-pro DEEPSEEK_REMOTE_PORT=8001 DEEPSEEK_LOCAL_PORT=18001 ;;
  3|kimi|kimi-k3) export DEEPSEEK_MODEL_SLUG=kimi-k3 DEEPSEEK_REMOTE_PORT=8002 DEEPSEEK_LOCAL_PORT=18002 ;;
  *) printf 'ERROR: nieznany model: %s\n' "$MODEL_INPUT" >&2; usage >&2; exit 2 ;;
esac
export MODEL_TUNNEL_NAME=${DEEPSEEK_MODEL_SLUG//[^a-zA-Z0-9._-]/_}
printf 'Wybrano: %s (PCSS:%s -> WSL:%s)\n' "$DEEPSEEK_MODEL_SLUG" "$DEEPSEEK_REMOTE_PORT" "$DEEPSEEK_LOCAL_PORT"
case "$ACTION" in
  status) exec "$CORE" --status ;;
  stop) exec "$CORE" --stop ;;
  connect) exec "$CORE" "$NODE" ;;
esac
