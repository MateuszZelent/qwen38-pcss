#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
VENDOR_DIR="${PROJECT_DIR}/vendor/codex-shim"
SETTINGS_PATH="${HOME}/.codex-shim/models.json"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-${HOME}/.cache}/qwen38-pcss"
PID_FILE="${RUNTIME_DIR}/${MODEL_TUNNEL_NAME:-deepseek}-tunnel.pid"
TUNNEL_LOG="${RUNTIME_DIR}/${MODEL_TUNNEL_NAME:-deepseek}-tunnel.log"

JUMP_HOST=${PCSS_SSH_LOGIN:-kkingstoun@eagle.man.poznan.pl}
COMPUTE_USER=${PCSS_COMPUTE_USER:-${JUMP_HOST%%@*}}
REMOTE_PORT=${DEEPSEEK_REMOTE_PORT:-8001}
LOCAL_PORT=${DEEPSEEK_LOCAL_PORT:-18001}
SHIM_PORT=${CODEX_ROUTER_PORT:-8765}
MODEL_SLUG=${DEEPSEEK_MODEL_SLUG:-deepseek-v4-pro}
HEALTH_PATH=${MODEL_HEALTH_PATH:-/health}
UPSTREAM_MODEL_ID=${UPSTREAM_MODEL_ID:-${MODEL_SLUG}}

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=12
  -o ConnectionAttempts=1
  -o GSSAPIAuthentication=no
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=accept-new
)

info() { printf '\n==> %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "brak wymaganego polecenia: $1"
}

listener_pids() {
  ss -H -ltnp "sport = :${LOCAL_PORT}" 2>/dev/null \
    | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' \
    | sort -u
}

shim() {
  PYTHONPATH="${VENDOR_DIR}${PYTHONPATH:+:${PYTHONPATH}}" \
    python3 -m codex_shim.cli --settings "${SETTINGS_PATH}" --port "${SHIM_PORT}" "$@"
}

show_status() {
  info "Porty lokalne"
  ss -ltnp 2>/dev/null | grep -E ":(${LOCAL_PORT}|${SHIM_PORT})[[:space:]]" || true
  info "Proces tunelu"
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid=$(<"${PID_FILE}")
    ps -p "${pid}" -o pid=,etime=,args= 2>/dev/null || warn "nieaktywny PID ${pid}"
  else
    pgrep -af "ssh.*127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" || true
  fi
  info "Health"
  curl -fsS --max-time 5 "http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH}" >/dev/null \
    && ok "vLLM tunnel" || warn "vLLM tunnel niedostępny"
  curl -fsS --max-time 5 "http://127.0.0.1:${SHIM_PORT}/health" \
    && printf '\n' || warn "codex-shim niedostępny"
}

stop_tunnel() {
  local pids=()
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid=$(<"${PID_FILE}")
    [[ "${pid}" =~ ^[0-9]+$ ]] && pids+=("${pid}")
  fi
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && pids+=("${pid}")
  done < <(listener_pids)

  local pid cmd
  for pid in "${pids[@]}"; do
    cmd=$(ps -p "${pid}" -o args= 2>/dev/null || true)
    [[ -z "${cmd}" ]] && continue
    if [[ "${cmd}" == ssh\ * && "${cmd}" == *"127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}"* ]]; then
      kill "${pid}" 2>/dev/null || true
    else
      die "port ${LOCAL_PORT} zajmuje proces niebędący naszym tunelem: PID=${pid} ${cmd}"
    fi
  done
  rm -f -- "${PID_FILE}"
  for _ in {1..20}; do
    [[ -z "$(listener_pids)" ]] && return 0
    sleep 0.2
  done
  die "nie udało się zwolnić portu ${LOCAL_PORT}"
}

case "${1:-}" in
  --status)
    show_status
    exit 0
    ;;
  --stop)
    stop_tunnel
    ok "tunel zatrzymany"
    exit 0
    ;;
esac

NODE=${1:-}
if [[ -z "${NODE}" ]]; then
  read -r -p "Główny węzeł joba DeepSeek (np. gpu44): " NODE
fi
[[ "${NODE}" =~ ^gpu[0-9]+$ ]] || die "nieprawidłowa nazwa węzła: ${NODE}"

for cmd in ssh curl ss sed sort python3; do need "${cmd}"; done
mkdir -p "${RUNTIME_DIR}"

info "1/8: zdalne API ${NODE}:${REMOTE_PORT}"
REMOTE_HEALTH=$(ssh "${SSH_OPTS[@]}" -J "${JUMP_HOST}" "${COMPUTE_USER}@${NODE}" \
  curl -fsS -i --max-time 15 "http://127.0.0.1:${REMOTE_PORT}${HEALTH_PATH}") \
  || die "API nie działa na ${NODE}:${REMOTE_PORT}; sprawdź log joba i czy ${NODE} jest pierwszym węzłem"
grep -q '200 OK' <<<"${REMOTE_HEALTH}" || die "zdalny ${HEALTH_PATH} nie zwrócił HTTP 200"
ok "zdalny ${HEALTH_PATH}"

REMOTE_MODELS=$(ssh "${SSH_OPTS[@]}" -J "${JUMP_HOST}" "${COMPUTE_USER}@${NODE}" \
  curl -fsS --max-time 15 "http://127.0.0.1:${REMOTE_PORT}/v1/models") \
  || die "zdalny /v1/models jest niedostępny"
REMOTE_MODELS="${REMOTE_MODELS}" UPSTREAM_MODEL_ID="${UPSTREAM_MODEL_ID}" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["REMOTE_MODELS"])
rows = payload.get("data", [])
target = next((row for row in rows if row.get("id") == os.environ["UPSTREAM_MODEL_ID"]), None)
if target is None:
    raise SystemExit(f"ERROR: brak modelu {os.environ['UPSTREAM_MODEL_ID']} w /v1/models")
print(f"OK: model={target['id']} max_model_len={target.get('max_model_len', 'unknown')}")
PY

info "2/8: przygotowanie portu ${LOCAL_PORT}"
if [[ -n "$(listener_pids)" ]]; then
  if curl -fsS --max-time 5 "http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH}" >/dev/null 2>&1 \
      && pgrep -af "ssh.*${NODE}.*127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" >/dev/null; then
    ok "istniejący tunel do ${NODE} jest zdrowy"
  else
    warn "zastępuję stary lub błędny tunel na porcie ${LOCAL_PORT}"
    stop_tunnel
  fi
fi

if [[ -z "$(listener_pids)" ]]; then
  info "3/8: uruchamianie tunelu SSH"
  nohup ssh -N -T "${SSH_OPTS[@]}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -J "${JUMP_HOST}" \
    -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
    "${COMPUTE_USER}@${NODE}" \
    >"${TUNNEL_LOG}" 2>&1 </dev/null &
  tunnel_pid=$!
  printf '%s\n' "${tunnel_pid}" >"${PID_FILE}"
  disown "${tunnel_pid}" 2>/dev/null || true

  for _ in {1..40}; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
      ok "tunel PID=${tunnel_pid}"
      break
    fi
    kill -0 "${tunnel_pid}" 2>/dev/null || {
      tail -30 "${TUNNEL_LOG}" >&2 || true
      die "proces tunelu zakończył się podczas startu"
    }
    sleep 0.5
  done
  curl -fsS --max-time 5 "http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH}" >/dev/null \
    || die "tunel istnieje, ale lokalny /health nie działa; log: ${TUNNEL_LOG}"
fi

info "4/8: konfiguracja i restart codex-shim"
case "${MODEL_SLUG}" in
  qwen3.8-27b) ROUTER_URL_ENV=PCSS_VLLM_BASE_URL ;;
  deepseek-v4-pro) ROUTER_URL_ENV=PCSS_DEEPSEEK_BASE_URL ;;
  kimi-k3) ROUTER_URL_ENV=PCSS_KIMI_BASE_URL ;;
  ornith-1.5-35b) ROUTER_URL_ENV=PCSS_ORNITH_BASE_URL ;;
  ornith-1.5-397b) ROUTER_URL_ENV=PCSS_ORNITH397_BASE_URL ;;
  *) die "brak mapowania endpointu routera dla ${MODEL_SLUG}" ;;
esac
export "${ROUTER_URL_ENV}=http://127.0.0.1:${LOCAL_PORT}/v1"
bash "${PROJECT_DIR}/scripts/setup-codex-router.sh" install >/dev/null
shim restart >/dev/null
shim model use "${MODEL_SLUG}" >/dev/null
curl -fsS --max-time 10 "http://127.0.0.1:${SHIM_PORT}/health" >/dev/null \
  || die "codex-shim nie odpowiada na porcie ${SHIM_PORT}"
ok "codex-shim"

info "5/8: konfiguracja Codexa"
CONFIG_PATH="${HOME}/.codex/config.toml"
[[ -f "${CONFIG_PATH}" ]] || die "brak ${CONFIG_PATH}"
grep -q "^model = \"${MODEL_SLUG}\"" "${CONFIG_PATH}" || die "Codex nie ma aktywnego ${MODEL_SLUG}"
grep -q '^model_provider = "codex_shim"' "${CONFIG_PATH}" || die "Codex nie używa provider=codex_shim"
grep -q "base_url = \"http://127.0.0.1:${SHIM_PORT}/v1\"" "${CONFIG_PATH}" \
  || die "Codex nie wskazuje shima na porcie ${SHIM_PORT}"
ok "model=${MODEL_SLUG}, provider=codex_shim"

info "6/8: bezpośrednia generacja vLLM"
direct_body=$(mktemp)
shim_body=$(mktemp)
trap 'rm -f -- "${direct_body:-}" "${shim_body:-}"' EXIT
printf '{"model":"%s","messages":[{"role":"user","content":"Return exactly DIRECT_OK and nothing else."}],"max_tokens":256,"temperature":0}' "${UPSTREAM_MODEL_ID}" >"${direct_body}"
DIRECT_RESPONSE=$(curl -fsS --max-time 180 -H 'Content-Type: application/json' \
  --data-binary "@${direct_body}" "http://127.0.0.1:${LOCAL_PORT}/v1/chat/completions") \
  || die "bezpośrednia generacja vLLM nie powiodła się"
DIRECT_RESPONSE="${DIRECT_RESPONSE}" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["DIRECT_RESPONSE"])
text = payload["choices"][0]["message"].get("content") or ""
if "DIRECT_OK" not in text:
    raise SystemExit(f"ERROR: nieoczekiwana odpowiedź direct: {text!r}")
print("OK: DIRECT_OK")
PY

info "7/8: generacja przez Responses API shima"
printf '{"model":"%s","input":"Return exactly SHIM_OK and nothing else.","max_output_tokens":256,"stream":false}' "${MODEL_SLUG}" >"${shim_body}"
SHIM_RESPONSE=$(curl -fsS --max-time 180 -H 'Content-Type: application/json' \
  --data-binary "@${shim_body}" "http://127.0.0.1:${SHIM_PORT}/v1/responses") \
  || die "generacja przez shim nie powiodła się"
SHIM_RESPONSE="${SHIM_RESPONSE}" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["SHIM_RESPONSE"])
texts = []
for item in payload.get("output", []):
    for part in item.get("content", []):
        if part.get("type") == "output_text":
            texts.append(part.get("text", ""))
text = "".join(texts)
if payload.get("status") != "completed" or "SHIM_OK" not in text:
    raise SystemExit(f"ERROR: nieoczekiwana odpowiedź shim: status={payload.get('status')} text={text!r}")
print("OK: SHIM_OK")
PY

info "8/8: opcjonalny test prawdziwego klienta Codex"
if command -v codex >/dev/null 2>&1; then
  answer=${RUN_CODEX_TEST:-}
  if [[ -z "${answer}" ]]; then
    read -r -p "Uruchomić test codex exec? [T/n]: " answer
  fi
  if [[ ! "${answer}" =~ ^[Nn]$ ]]; then
    timeout 240 codex exec --model "${MODEL_SLUG}" 'Return exactly CODEX_OK and nothing else.' 2>&1 \
      | tee /tmp/qwen38-pcss-codex-test.out
    grep -q 'CODEX_OK' /tmp/qwen38-pcss-codex-test.out || die "codex exec nie zwrócił CODEX_OK"
    ok "CODEX_OK"
  else
    warn "pominięto codex exec"
  fi
else
  warn "codex CLI nie jest dostępny w PATH"
fi

printf '\nGOTOWE\n'
printf '  PCSS:       %s:%s\n' "${NODE}" "${REMOTE_PORT}"
printf '  Tunel WSL:  http://127.0.0.1:%s\n' "${LOCAL_PORT}"
printf '  Shim:       http://127.0.0.1:%s/v1\n' "${SHIM_PORT}"
printf '  Model:      %s\n' "${MODEL_SLUG}"
printf '  PID:        %s\n' "$(<"${PID_FILE}")"
printf '  Log tunelu: %s\n' "${TUNNEL_LOG}"
