#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
DEF_FILE=${DEF_FILE:-"${PROJECT_DIR}/apptainer/qwen38-vllm.def"}
OUTPUT_IMAGE=${OUTPUT_IMAGE:-"${PROJECT_DIR}/qwen38-vllm.sif"}
BUILD_MODE=${APPTAINER_BUILD_MODE:-fakeroot}

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

[[ -f "${DEF_FILE}" ]] || {
  echo "ERROR: definition file not found: ${DEF_FILE}" >&2
  exit 2
}

TMP_ROOT=${APPTAINER_TMPDIR:-"${PROJECT_DIR}/.apptainer-tmp"}
mkdir -p "${TMP_ROOT}"
export APPTAINER_TMPDIR="${TMP_ROOT}"
export SINGULARITY_TMPDIR="${TMP_ROOT}"

if [[ -e "${OUTPUT_IMAGE}" ]]; then
  echo "ERROR: output already exists: ${OUTPUT_IMAGE}" >&2
  echo "Move it aside or set OUTPUT_IMAGE to a new path." >&2
  exit 3
fi

case "${BUILD_MODE}" in
  fakeroot)
    "${RUNTIME_BIN}" build --fakeroot "${OUTPUT_IMAGE}" "${DEF_FILE}"
    ;;
  userns)
    "${RUNTIME_BIN}" build --userns "${OUTPUT_IMAGE}" "${DEF_FILE}"
    ;;
  privileged)
    "${RUNTIME_BIN}" build "${OUTPUT_IMAGE}" "${DEF_FILE}"
    ;;
  *)
    echo "ERROR: APPTAINER_BUILD_MODE must be fakeroot, userns, or privileged" >&2
    exit 4
    ;;
esac

echo "Built: ${OUTPUT_IMAGE}"
