#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
ARTIFACT_ROOT=${ARTIFACT_ROOT:-${REPO_ROOT}/artifacts}
KERNEL_ID=${KERNEL_ID:?KERNEL_ID is required}
COMPILER=${COMPILER:-gcc}
KERNEL_CONFIG=${KERNEL_CONFIG:-defconfig}
PATCH_SERIES=${KERNEL_PATCHES:-}
ARCHIVE_CANDIDATES_STR=${KERNEL_ARCHIVE_CANDIDATES:-}
GIT_REPO=${KERNEL_GIT_REPO:-}
GIT_REF=${KERNEL_GIT_REF:-}

read -r -a ARCHIVE_CANDIDATES <<< "$ARCHIVE_CANDIDATES_STR"
read -r -a PATCH_LIST <<< "$PATCH_SERIES"

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
  if [[ "${COMPILER}" == "clang" ]]; then
    export LLVM=1
    export CC=clang
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
  # Сборка напрямую через kbuild выбранного ядра — без /lib/modules/$(uname -r)
  pushd "${REPO_ROOT}/fs/aufs" >/dev/null
  make -C "${tree}" M="$PWD" \
       EXTRA_CFLAGS="-I${REPO_ROOT}/include -DCONFIG_AUFS_FS_MODULE -UCONFIG_AUFS -DCONFIG_AUFS_BRANCH_MAX_127 -DCONFIG_AUFS_SBILIST" \
       clean
  make -C "${tree}" M="$PWD" \
       EXTRA_CFLAGS="-I${REPO_ROOT}/include -DCONFIG_AUFS_FS_MODULE -UCONFIG_AUFS -DCONFIG_AUFS_BRANCH_MAX_127 -DCONFIG_AUFS_SBILIST" \
       -j"$(nproc)" modules
  cp aufs.ko "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/aufs.ko"
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
