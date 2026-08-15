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

: "${MODEL_ID:?MODEL_ID is required}"
: "${MODEL_ROOT:?MODEL_ROOT is required}"
: "${SIF:?SIF is required}"

RUNTIME_BIN=${CONTAINER_RUNTIME:-}
if [[ -z "${RUNTIME_BIN}" ]]; then
  if command -v apptainer >/dev/null 2>&1; then
    RUNTIME_BIN=apptainer
  elif command -v singularity >/dev/null 2>&1; then
    RUNTIME_BIN=singularity
  else
    echo "ERROR: neither apptainer nor singularity is available in PATH" >&2
    exit 127
  fi
fi
[[ -f "${SIF}" ]] || {
  echo "ERROR: image not found: ${SIF}" >&2
  exit 3
}

mkdir -p "${MODEL_ROOT}"
export APPTAINERENV_HF_HOME=/models/.hf-cache
export APPTAINERENV_HF_HUB_DISABLE_TELEMETRY=1
if [[ -n "${HF_TOKEN:-}" ]]; then
  export APPTAINERENV_HF_TOKEN="${HF_TOKEN}"
fi

CONTAINER_MODEL_DIR="/models/${MODEL_SUBDIR:-Qwen3.8-27B}"

"${RUNTIME_BIN}" exec \
  --bind "${MODEL_ROOT}:/models" \
  "${SIF}" \
  python3 - "${MODEL_ID}" "${CONTAINER_MODEL_DIR}" <<'PY'
import os
import sys
from huggingface_hub import snapshot_download

repo_id, local_dir = sys.argv[1:]
token = os.environ.get("HF_TOKEN") or None
print(f"Downloading {repo_id} to {local_dir}", flush=True)
snapshot_download(repo_id=repo_id, local_dir=local_dir, token=token)
print("Model download complete", flush=True)
PY
