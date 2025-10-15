#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
ARTIFACT_ROOT=${ARTIFACT_ROOT:-${REPO_ROOT}/artifacts}
KERNEL_ID=${KERNEL_ID:?KERNEL_ID is required}
COMPILER=${COMPILER:-gcc}
KERNEL_CONFIG=${KERNEL_CONFIG:-defconfig}
PATCH_SERIES=${KERNEL_PATCHES:-}
ARCHIVE_CANDIDATES_STR=${KERNEL_ARCHIVE_CANDIDATES:-}
GIT_REPO=${KERNEL_GIT_REPO:-}
GIT_REF=${KERNEL_GIT_REF:-}

# Convert space-separated strings to arrays safely
read -r -a ARCHIVE_CANDIDATES <<< "$ARCHIVE_CANDIDATES_STR"
read -r -a PATCH_LIST <<< "$PATCH_SERIES"

workdir=$(mktemp -d)
cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

fetch_kernel() {
  local dest=$1
  if [[ ${#ARCHIVE_CANDIDATES[@]} -gt 0 ]]; then
    local url
    for url in "${ARCHIVE_CANDIDATES[@]}"; do
      # Trim whitespace
      url=$(echo "$url" | xargs)
      [[ -z "$url" ]] && continue
      echo "::group::Downloading ${url}"
      if curl -fsSL "${url}" -o "${dest}/kernel.tar.xz"; then
        echo "::endgroup::"
        tar -xf "${dest}/kernel.tar.xz" -C "${dest}"
        local top
        top=$(tar -tf "${dest}/kernel.tar.xz" | head -n1 | cut -d/ -f1)
        echo "${dest}/${top}"
        return 0
      fi
      echo "::warning title=Download failed::${url}" >&2
      echo "::endgroup::"
    done
    echo "::error title=Kernel archive not found::tried ${ARCHIVE_CANDIDATES[*]}" >&2
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
  if [[ ${#PATCH_LIST[@]} -eq 0 ]]; then
    return
  fi
  pushd "${tree}" >/dev/null
  for patch in "${PATCH_LIST[@]}"; do
    patch=$(echo "$patch" | xargs)
    [[ -z "$patch" ]] && continue
    echo "::group::Applying ${patch}"
    patch -p1 < "${REPO_ROOT}/${patch}"
    echo "::endgroup::"
  done
  popd >/dev/null
}

setup_compiler() {
  if [[ "${COMPILER}" == "clang" ]]; then
    export LLVM=1
    export CC=clang
    export LD=ld.lld
  else
    unset LLVM CC LD
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

  cat <<EOF >"${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/build.json"
{
  "kernel_id": "${KERNEL_ID}",
  "compiler": "${COMPILER}",
  "kernel_config": "${KERNEL_CONFIG}",
  "patches": [$(printf '"%s"' "${PATCH_LIST[@]}" | sed 's/""//g; s/""/, "/g')]
}
EOF
}

main "$@"
