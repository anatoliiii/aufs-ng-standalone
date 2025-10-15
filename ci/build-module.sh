#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
ARTIFACT_ROOT=${ARTIFACT_ROOT:-${REPO_ROOT}/artifacts}
KERNEL_ID=${KERNEL_ID:?KERNEL_ID is required}
COMPILER=${COMPILER:-gcc}
KERNEL_CONFIG=${KERNEL_CONFIG:-defconfig}
ARCHIVE_CANDIDATES_STR=${KERNEL_ARCHIVE_CANDIDATES:-}
GIT_REPO=${KERNEL_GIT_REPO:-}
GIT_REF=${KERNEL_GIT_REF:-}

DEFAULT_AUFS_PATCHES=(
  "aufs6-base.patch"
  "aufs6-mmap.patch"
  "aufs6-standalone.patch"
)

INCLUDE_DEFAULT_AUFS_PATCHES=${INCLUDE_DEFAULT_AUFS_PATCHES:-1}

declare -a PATCH_LIST=()
declare -A PATCH_SEEN=()

add_patch() {
  local patch
  patch=$(echo "$1" | xargs)
  [[ -z "${patch}" ]] && return
  if [[ -n "${PATCH_SEEN[${patch}]:-}" ]]; then
    return
  fi
  PATCH_LIST+=("${patch}")
  PATCH_SEEN["${patch}"]=1
}

read -r -a ARCHIVE_CANDIDATES <<< "$ARCHIVE_CANDIDATES_STR"

if [[ "${INCLUDE_DEFAULT_AUFS_PATCHES}" != "0" ]]; then
  for patch in "${DEFAULT_AUFS_PATCHES[@]}"; do
    add_patch "${patch}"
  done
fi

if [[ -n "${KERNEL_PATCHES:-}" ]]; then
  read -r -a USER_PATCHES <<< "${KERNEL_PATCHES}"
  for patch in "${USER_PATCHES[@]}"; do
    add_patch "${patch}"
  done
fi

workdir=$(mktemp -d)
cleanup() { rm -rf "${workdir}"; }
trap cleanup EXIT

log() { printf '%s\n' "$*" >&2; }

fetch_kernel() {
  local dest=$1
  if [[ ${#ARCHIVE_CANDIDATES[@]} -gt 0 ]]; then
    local url
    for url in "${ARCHIVE_CANDIDATES[@]}"; do
      url=$(echo "$url" | xargs)
      [[ -z "$url" ]] && continue
      log "::group::Downloading ${url}"
      if wget -nv --tries=3 --timeout=30 -O "${dest}/kernel.tar.xz" "${url}"; then
        log "::endgroup::"
        tar -xf "${dest}/kernel.tar.xz" -C "${dest}"
        # ВАЖНО: не ломаем пайп, глушим STDERR, забираем первую строку и первый компонент пути
        local top
        top=$(tar -tf "${dest}/kernel.tar.xz" 2>/dev/null | sed -n '1s;/.*;;p')
        echo "${dest}/${top}"  # только путь ядра в stdout
        return 0
      fi
      log "::warning title=Download failed::${url}"
      log "::endgroup::"
    done
    log "::error title=Kernel archive not found::tried ${ARCHIVE_CANDIDATES[*]}"
    return 1
  fi

  if [[ -n "${GIT_REPO}" ]]; then
    log "::group::Cloning ${GIT_REPO}@${GIT_REF}"
    git clone --depth 1 --branch "${GIT_REF}" "${GIT_REPO}" "${dest}/kernel"
    log "::endgroup::"
    echo "${dest}/kernel"
    return 0
  fi

  log "::error title=No kernel source specified::set KERNEL_ARCHIVE_CANDIDATES or KERNEL_GIT_REPO"
  return 1
}

prepare_kernel() {
  local tree=$1
  pushd "${tree}" >/dev/null
  make mrproper
  make "${KERNEL_CONFIG}"
  if [[ -f "${REPO_ROOT}/ci/aufs.config" ]]; then
    ./scripts/kconfig/merge_config.sh .config "${REPO_ROOT}/ci/aufs.config"
    yes "" | make oldconfig >/dev/null
  fi
  make modules_prepare
  popd >/dev/null
}

apply_one_patch() {
  local tree=$1
  local patch_file=$2

  # пробуем тихую проверку patch(1)
  if patch -p1 --dry-run < "${patch_file}" >/dev/null 2>&1; then
    patch -p1 < "${patch_file}"
    return 0
  fi
  # fallback на git apply (не требует git-репозитория)
  if git apply --check "${patch_file}" >/dev/null 2>&1; then
    git apply "${patch_file}"
    return 0
  fi
  return 1
}

apply_patches() {
  local tree=$1
  [[ ${#PATCH_LIST[@]} -eq 0 ]] && return 0
  pushd "${tree}" >/dev/null
  local p
  for p in "${PATCH_LIST[@]}"; do
    p=$(echo "$p" | xargs)
    [[ -z "$p" ]] && continue
    local pf="${REPO_ROOT}/${p}"
    if [[ ! -f "${pf}" ]]; then
      log "::error title=Patch not found::${pf}"
      exit 1
    fi
    log "::group::Applying ${p}"
    if ! apply_one_patch "${tree}" "${pf}"; then
      log "::error title=Patch failed::${p}"
      exit 1
    fi
    log "::endgroup::"
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
  else
    unset LLVM CC LD
  fi
}

json_array_from_list() {
  local arr=("$@")
  local out=""
  for e in "${arr[@]}"; do
    [[ -z "$e" ]] && continue
    out+=$(printf '%s"%s"' "${out:+, }" "$e")
  done
  printf '[%s]' "${out}"
}

main() {
  setup_compiler
  local tree
  tree=$(fetch_kernel "${workdir}")
  mkdir -p "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}"
  apply_patches "${tree}"
  prepare_kernel "${tree}"
  # Сборка напрямую через kbuild выбранного ядра — без /lib/modules/$(uname -r)
  pushd "${REPO_ROOT}" >/dev/null
  make KDIR="${tree}" clean
  make KDIR="${tree}" -j"$(nproc)" fs/aufs/aufs.ko
  cp fs/aufs/aufs.ko "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/aufs.ko"
  popd >/dev/null

  local patches_json
  patches_json=$(json_array_from_list "${PATCH_LIST[@]}")

  cat >"${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/build.json" <<EOF
{
  "kernel_id": "${KERNEL_ID}",
  "compiler": "${COMPILER}",
  "kernel_config": "${KERNEL_CONFIG}",
  "patches": ${patches_json}
}
EOF
}

main "$@"
