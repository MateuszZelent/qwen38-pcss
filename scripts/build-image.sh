#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
IMAGE_PROFILE=${IMAGE_PROFILE:-qwen38}
case "${IMAGE_PROFILE}" in
  qwen38)
    DEFAULT_DEF="${PROJECT_DIR}/apptainer/qwen38-vllm.def"
    DEFAULT_OUTPUT="${PROJECT_DIR}/qwen38-vllm.sif"
    ;;
  deepseek-v4-pro)
    DEFAULT_DEF="${PROJECT_DIR}/apptainer/deepseek-v4-vllm.def"
    DEFAULT_OUTPUT="${PROJECT_DIR}/deepseek-v4-vllm.sif"
    ;;
  kimi-k3)
    DEFAULT_DEF="${PROJECT_DIR}/apptainer/kimi-k3-vllm.def"
    DEFAULT_OUTPUT="${PROJECT_DIR}/kimi-k3-vllm.sif"
    ;;
  *)
    echo "ERROR: IMAGE_PROFILE must be qwen38, deepseek-v4-pro, or kimi-k3" >&2
    exit 4
    ;;
esac
DEF_FILE=${DEF_FILE:-"${DEFAULT_DEF}"}
OUTPUT_IMAGE=${OUTPUT_IMAGE:-"${DEFAULT_OUTPUT}"}
BUILD_MODE=${APPTAINER_BUILD_MODE:-${SINGULARITY_BUILD_MODE:-fakeroot}}

# PCSS exposes a privileged wrapper which is not present in the user's PATH:
#   sudo singularity-build <IMAGE PATH> <BUILD SPEC>
# Keep the wrapper opt-in so this script remains usable on regular Apptainer
# installations where fakeroot or user namespaces are available.
SUDO_BIN=${SUDO_BIN:-sudo}
BUILD_WRAPPER=${SINGULARITY_BUILD_WRAPPER:-singularity-build}

RUNTIME_BIN=${CONTAINER_RUNTIME:-}
if [[ "${BUILD_MODE}" != "admin-wrapper" && -z "${RUNTIME_BIN}" ]]; then
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

CACHE_ROOT=${APPTAINER_CACHEDIR:-"${PROJECT_DIR}/.apptainer-cache"}
mkdir -p "${CACHE_ROOT}"
export APPTAINER_CACHEDIR="${CACHE_ROOT}"
export SINGULARITY_CACHEDIR="${CACHE_ROOT}"

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
  admin-wrapper)
    command -v "${SUDO_BIN}" >/dev/null 2>&1 || {
      echo "ERROR: sudo is not available: ${SUDO_BIN}" >&2
      exit 127
    }
    echo "Using PCSS privileged build wrapper: ${SUDO_BIN} ${BUILD_WRAPPER}" >&2
    "${SUDO_BIN}" "${BUILD_WRAPPER}" "${OUTPUT_IMAGE}" "${DEF_FILE}"
    ;;
  *)
    echo "ERROR: APPTAINER_BUILD_MODE must be fakeroot, userns, privileged, or admin-wrapper" >&2
    exit 4
    ;;
esac

echo "Built: ${OUTPUT_IMAGE}"
