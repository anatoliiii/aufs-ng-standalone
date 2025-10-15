#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
ARTIFACT_ROOT=${ARTIFACT_ROOT:-${REPO_ROOT}/artifacts}
KERNEL_ID=${KERNEL_ID:?KERNEL_ID is required}
COMPILER=${COMPILER:-gcc}
KERNEL_CONFIG=${KERNEL_CONFIG:-defconfig}
PATCH_SERIES=${KERNEL_PATCHES:-}
ARCHIVE_CANDIDATES=${KERNEL_ARCHIVE_CANDIDATES:-}
GIT_REPO=${KERNEL_GIT_REPO:-}
GIT_REF=${KERNEL_GIT_REF:-}

workdir=$(mktemp -d)
cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

fetch_kernel() {
  local dest=$1
  if [[ -n "${ARCHIVE_CANDIDATES}" ]]; then
    local url
    for url in ${ARCHIVE_CANDIDATES}; do
      echo "::group::Downloading ${url}" >&2
      if curl -fsSL "${url}" -o "${dest}/kernel.tar.xz"; then
        echo "::endgroup::" >&2
        tar -xf "${dest}/kernel.tar.xz" -C "${dest}"
        local top
        top=$(tar -tf "${dest}/kernel.tar.xz" | sed -n '1p' | cut -d/ -f1)
        echo "${dest}/${top}"
        return 0
      fi
      echo "::warning title=Download failed::${url}" >&2
      echo "::endgroup::" >&2
    done
    echo "::error title=Kernel archive not found::tried ${ARCHIVE_CANDIDATES}" >&2
    return 1
  fi
  if [[ -n "${GIT_REPO}" ]]; then
    echo "::group::Cloning ${GIT_REPO}@${GIT_REF}" >&2
    git clone --depth 1 --branch "${GIT_REF}" "${GIT_REPO}" "${dest}/kernel"
    echo "::endgroup::" >&2
    echo "${dest}/kernel"
    return 0
  fi
  echo "::error title=No kernel source specified::set KERNEL_ARCHIVE_CANDIDATES or KERNEL_GIT_REPO" >&2
  return 1
}

prepare_kernel() {
  local tree=$1
  pushd "${tree}" >/dev/null
  make mrproper
  make "${KERNEL_CONFIG}"
  make modules_prepare
  popd >/dev/null
}

apply_patches() {
  local tree=$1
  if [[ -z "${PATCH_SERIES}" ]]; then
    return
  fi
  pushd "${tree}" >/dev/null
  for patch in ${PATCH_SERIES}; do
    echo "::group::Applying ${patch}"
    patch -p1 < "${REPO_ROOT}/${patch}"
    echo "::endgroup::"
  done
  popd >/dev/null
}

setup_compiler() {
  if [[ "${COMPILER}" != "clang" ]]; then
    return
  fi

  local required_major=15
  local clang_bin=""
  local clang_major=""

  if command -v clang >/dev/null 2>&1; then
    clang_major=$(clang --version | sed -n '1s/.*version \([0-9]\+\).*/\1/p')
    if [[ -n "${clang_major}" && ${clang_major} -ge ${required_major} ]]; then
      clang_bin=$(command -v clang)
    fi
  fi

  if [[ -z "${clang_bin}" ]]; then
    local candidate
    for candidate in $(seq 20 -1 ${required_major}); do
      if command -v "clang-${candidate}" >/dev/null 2>&1; then
        clang_bin=$(command -v "clang-${candidate}")
        clang_major=${candidate}
        break
      fi
    done
  fi

  if [[ -z "${clang_bin}" ]]; then
    echo "::error title=Missing clang::Need clang ${required_major} or newer for kernel build" >&2
    exit 1
  fi

  export LLVM=1

  if [[ "${clang_bin}" =~ clang-([0-9]+)$ ]]; then
    export LLVM_SUFFIX="-${BASH_REMATCH[1]}"
  else
    unset LLVM_SUFFIX
  fi

  export CC="${clang_bin}"
  export HOSTCC="${clang_bin}"

  local hostcxx_candidate="clang++"
  if [[ -n "${LLVM_SUFFIX:-}" ]]; then
    hostcxx_candidate="clang++${LLVM_SUFFIX}"
  fi
  if command -v "${hostcxx_candidate}" >/dev/null 2>&1; then
    export HOSTCXX="${hostcxx_candidate}"
  fi

  if [[ -n "${LLVM_SUFFIX:-}" ]]; then
    if command -v "ld.lld${LLVM_SUFFIX}" >/dev/null 2>&1; then
      export LD="ld.lld${LLVM_SUFFIX}"
      return
    fi
  fi

  if command -v ld.lld >/dev/null 2>&1; then
    export LD=ld.lld
  fi
}

main() {
  setup_compiler
  local tree
  tree=$(fetch_kernel "${workdir}")
  apply_patches "${tree}"
  prepare_kernel "${tree}"

  mkdir -p "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}"
  pushd "${REPO_ROOT}" >/dev/null
  KDIR="${tree}" make clean
  KDIR="${tree}" make all
  cp fs/aufs/aufs.ko "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/aufs.ko"
  popd >/dev/null

  cat <<JSON >"${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/build.json"
{
  "kernel_id": "${KERNEL_ID}",
  "compiler": "${COMPILER}",
  "kernel_config": "${KERNEL_CONFIG}",
  "patches": "${PATCH_SERIES}"
}
JSON
}

main "$@"
