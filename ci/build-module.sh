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
cleanup() { rm -rf "${workdir}"; }
trap cleanup EXIT

fetch_kernel() {
  local dest=$1
  mkdir -p "${dest}"
  if [[ -n "${ARCHIVE_CANDIDATES}" ]]; then
    local url
    for url in ${ARCHIVE_CANDIDATES}; do
      echo "::group::Downloading ${url}"
      if curl -fsSL "${url}" -o "${dest}/kernel.tar.xz"; then
        echo "::endgroup::"
        tar -C "${dest}" -xf "${dest}/kernel.tar.xz"
        local top
        top=$(tar -tf "${dest}/kernel.tar.xz" | head -1 | cut -d/ -f1)
        echo "${dest}/${top}"
        return 0
      fi
      echo "::warning title=Download failed::${url}" >&2
      echo "::endgroup::"
    done
    echo "::error title=Kernel archive not found::tried ${ARCHIVE_CANDIDATES}" >&2
    return 1
  fi
  if [[ -n "${GIT_REPO}" ]]; then
    echo "::group::Cloning ${GIT_REPO}@${GIT_REF}"
    git clone --depth 1 --branch "${GIT_REF}" "${GIT_REPO}" "${dest}/kernel"
    echo "::endgroup::"
    echo "${dest}/kernel"
    return 0
  fi
  echo "::error title=No kernel source specified::set KERNEL_ARCHIVE_CANDIDATES or KERNEL_GIT_REPO" >&2
  return 1
}

apply_patches() {
  local tree=$1
  [[ -z "${PATCH_SERIES}" ]] && return 0
  pushd "${tree}" >/dev/null
  for patch in ${PATCH_SERIES}; do
    echo "::group::Applying ${patch}"
    patch -p1 < "${REPO_ROOT}/${patch}"
    echo "::endgroup::"
  done
  popd >/dev/null
}

prepare_kernel() {
  local tree=$1
  pushd "${tree}" >/dev/null
  make mrproper
  make "${KERNEL_CONFIG}"
  make modules_prepare
  popd >/dev/null
}

setup_compiler() {
  if [[ "${COMPILER}" == "clang" ]]; then
    export LLVM=1
    export CC=clang
    export LD=ld.lld
  else
    unset LLVM || true
    export CC=gcc
  fi
}

build_aufs_module() {
  local tree=$1
  # AUFS как внешний модуль: строго против KDIR=tree
  make -C "${tree}" M="${REPO_ROOT}/fs/aufs" clean
  make -C "${tree}" M="${REPO_ROOT}/fs/aufs" modules
}

main() {
  setup_compiler
  local tree
  tree=$(fetch_kernel "${workdir}")
  apply_patches "${tree}"
  prepare_kernel "${tree}"

  mkdir -p "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}"
  build_aufs_module "${tree}"
  cp "${REPO_ROOT}/fs/aufs/aufs.ko" "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/aufs.ko"

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
