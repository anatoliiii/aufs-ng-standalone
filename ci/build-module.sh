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

# Symvers behavior (can be overridden in env)
STRICT_SYMVERS=${STRICT_SYMVERS:-1}      # 1 = fail if MODVERSIONS=y and no Module.symvers
GENERATE_SYMVERS=${GENERATE_SYMVERS:-0}  # 1 = run "make modules" to produce Module.symvers
SYMVERS_FROM=${SYMVERS_FROM:-}            # explicit path to Module.symvers

DEFAULT_AUFS_PATCHES=(
  "aufs6-base.patch"
  "aufs6-mmap.patch"
  "aufs6-standalone.patch"
  "aufs6-kbuild.patch"
)

INCLUDE_DEFAULT_AUFS_PATCHES=${INCLUDE_DEFAULT_AUFS_PATCHES:-1}
APT_HAS_UPDATED=0

declare -a PATCH_LIST=()
declare -A PATCH_SEEN=()

log() { printf '%s\n' "$*" >&2; }

add_patch() {
  local patch; patch=$(echo "$1" | xargs)
  [[ -z "${patch}" ]] && return
  [[ -n "${PATCH_SEEN[${patch}]:-}" ]] && return
  PATCH_LIST+=("${patch}")
  PATCH_SEEN["${patch}"]=1
}

read -r -a ARCHIVE_CANDIDATES <<< "$ARCHIVE_CANDIDATES_STR"

if [[ "${INCLUDE_DEFAULT_AUFS_PATCHES}" != "0" ]]; then
  for patch in "${DEFAULT_AUFS_PATCHES[@]}"; do add_patch "${patch}"; done
fi

ensure_build_dependencies() {
  local -a missing=()
  local tool
  for tool in flex bison bc python3 kmod; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  [[ -f /usr/include/gelf.h ]] || missing+=("libelf-dev")
  [[ ${#missing[@]} -eq 0 ]] && return

  local -a runner=()
  if [[ $(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1; then runner+=(sudo); fi
  command -v apt-get >/dev/null 2>&1 || { printf '::error title=Missing tools::need %s\n' "${missing[*]}" >&2; exit 1; }
  if [[ ${APT_HAS_UPDATED} -eq 0 ]]; then "${runner[@]}" apt-get update; APT_HAS_UPDATED=1; fi
  "${runner[@]}" apt-get install -y --no-install-recommends "${missing[@]}"
}

if [[ -n "${KERNEL_PATCHES:-}" ]]; then
  read -r -a USER_PATCHES <<< "${KERNEL_PATCHES}"
  for patch in "${USER_PATCHES[@]}"; do add_patch "${patch}"; done
fi

workdir=$(mktemp -d)
cleanup() { rm -rf "${workdir}"; }
trap cleanup EXIT

fetch_kernel() {
  local dest=$1
  if [[ ${#ARCHIVE_CANDIDATES[@]} -gt 0 ]]; then
    local url
    for url in "${ARCHIVE_CANDIDATES[@]}"; do
      url=$(echo "$url" | xargs); [[ -z "$url" ]] && continue
      log "::group::Downloading ${url}"
      if wget -nv --tries=3 --timeout=30 -O "${dest}/kernel.tar.xz" "${url}"; then
        log "::endgroup::"
        tar -xf "${dest}/kernel.tar.xz" -C "${dest}"
        local top; top=$(tar -tf "${dest}/kernel.tar.xz" 2>/dev/null | sed -n '1s;/.*;;p')
        echo "${dest}/${top}"
        return 0
      fi
      log "::warning title=Download failed::${url}"
      log "::endgroup::"
    done
    log "::error title=Kernel archive not found::tried ${ARCHIVE_CANDIDATES[*]}"; return 1
  fi

  if [[ -n "${GIT_REPO}" ]]; then
    log "::group::Cloning ${GIT_REPO}@${GIT_REF}"
    git clone --depth 1 --branch "${GIT_REF}" "${GIT_REPO}" "${dest}/kernel"
    log "::endgroup::"
    echo "${dest}/kernel"; return 0
  fi

  log "::error title=No kernel source specified::set KERNEL_ARCHIVE_CANDIDATES or KERNEL_GIT_REPO"; return 1
}

apply_config_fragment() {
  local fragment=$1
  [[ ! -f "${fragment}" ]] && return 0

  # helper: does symbol exist in any Kconfig?
  kconfig_has() { grep -R -n --include=Kconfig -E "^[[:space:]]*config[[:space:]]+${1}\b" . >/dev/null 2>&1; }

  # Unhide gatekeepers so AUFS options are visible
  ./scripts/config --file .config --enable EXPERT || true
  ./scripts/config --file .config --enable MODULES || true
  ./scripts/config --file .config --enable FS_XATTR || true
  ./scripts/config --file .config --enable FS_POSIX_ACL || true
  ./scripts/config --file .config --enable FSNOTIFY || true
  ./scripts/config --file .config --enable INOTIFY_USER || true
  ./scripts/config --file .config --enable FHANDLE || true
  ./scripts/config --file .config --enable NLS || true
  make olddefconfig >/dev/null

  local -a expectations=()
  while IFS= read -r raw; do
    [[ -z "${raw}" ]] && continue
    case "${raw}" in
      "# CONFIG_"*" is not set")
        local symbol=${raw#\# }; symbol=${symbol% is not set}; symbol=${symbol#CONFIG_}
        if kconfig_has "${symbol}"; then
          ./scripts/config --file .config --disable "${symbol}" || true
          expectations+=("${symbol}:n")
        else
          printf '::notice title=Skip undefined Kconfig symbol::%s (n)\n' "${symbol}" >&2
        fi
        continue
        ;;
      "#"*) continue ;;
    esac
    local line=${raw%%#*}; line=$(echo "${line}" | xargs); [[ -z "${line}" ]] && continue
    case "${line}" in
      CONFIG_*=m)
        local symbol=${line%%=*}; symbol=${symbol#CONFIG_}
        if kconfig_has "${symbol}"; then
          ./scripts/config --file .config --module "${symbol}" || true
          expectations+=("${symbol}:m")
        else
          printf '::notice title=Skip undefined Kconfig symbol::%s (m)\n' "${symbol}" >&2
        fi
        ;;
      CONFIG_*=y)
        local symbol=${line%%=*}; symbol=${symbol#CONFIG_}
        if kconfig_has "${symbol}"; then
          ./scripts/config --file .config --enable "${symbol}" || true
          expectations+=("${symbol}:y")
        else
          printf '::notice title=Skip undefined Kconfig symbol::%s (y)\n' "${symbol}" >&2
        fi
        ;;
      CONFIG_*=n)
        local symbol=${line%%=*}; symbol=${symbol#CONFIG_}
        if kconfig_has "${symbol}"; then
          ./scripts/config --file .config --disable "${symbol}" || true
          expectations+=("${symbol}:n")
        else
          printf '::notice title=Skip undefined Kconfig symbol::%s (n)\n' "${symbol}" >&2
        fi
        ;;
    esac
  done < "${fragment}"

  make olddefconfig >/dev/null

  local missing=0
  local entry
  for entry in "${expectations[@]}"; do
    local symbol=${entry%%:*}; local want=${entry#*:}
    kconfig_has "${symbol}" || { printf '::notice title=Expectation skipped (no symbol)::%s\n' "${symbol}" >&2; continue; }
    case "${want}" in
      m|y)
        if ! grep -q "^CONFIG_${symbol}=${want}$" .config; then
          printf 'Expected CONFIG_%s=%s in merged config\n' "${symbol}" "${want}" >&2; missing=1
        fi
        ;;
      n)
        if ! grep -q "^# CONFIG_${symbol} is not set" .config; then
          printf 'Expected # CONFIG_%s is not set in merged config\n' "${symbol}" >&2; missing=1
        fi
        ;;
    esac
  done

  if [[ ${missing} -ne 0 ]]; then
    printf '::error title=Incomplete kernel config::Failed to apply %s\n' "${fragment}" >&2
    exit 1
  fi
}

prepare_kernel() {
  local tree=$1
  pushd "${tree}" >/dev/null
  make mrproper
  make "${KERNEL_CONFIG}"
  [[ -f "${REPO_ROOT}/ci/aufs.config" ]] && apply_config_fragment "${REPO_ROOT}/ci/aufs.config"
  make modules_prepare
  popd >/dev/null
}

detect_vfs_compat_flags() {
  local tree=$1
  local fs_header="${tree}/include/linux/fs.h"
  local dcache_header="${tree}/include/linux/dcache.h"
  local -a flags=()

  if python3 - "$fs_header" <<'PY'
import re, sys; d=open(sys.argv[1]).read()
sys.exit(0 if re.search(r'\bs_d_op\b', d) else 1)
PY
  then flags+=('-DAUFS_KBUILD_HAS_SB_S_D_OP'); fi

  if python3 - "$dcache_header" <<'PY'
import re, sys; d=open(sys.argv[1]).read()
sys.exit(0 if re.search(r'\bd_set_d_op\b', d) else 1)
PY
  then flags+=('-DAUFS_KBUILD_HAS_D_SET_D_OP'); fi

  if python3 - "$fs_header" <<'PY'
import re, sys; d=open(sys.argv[1]).read()
sys.exit(0 if re.search(r'\bold_parent\s*;', d) else 1)
PY
  then flags+=('-DAUFS_KBUILD_RENAMEDATA_HAS_PARENTS'); fi

  printf '%s' "${flags[*]}"
}

apply_one_patch() {
  local tree=$1; local patch_file=$2
  if patch -p1 --dry-run < "${patch_file}" >/dev/null 2>&1; then patch -p1 < "${patch_file}"; return 0; fi
  if git apply --check "${patch_file}" >/dev/null 2>&1; then git apply "${patch_file}"; return 0; fi
  return 1
}

apply_patches() {
  local tree=$1
  [[ ${#PATCH_LIST[@]} -eq 0 ]] && return 0
  pushd "${tree}" >/dev/null
  local p pf
  for p in "${PATCH_LIST[@]}"; do
    p=$(echo "$p" | xargs); [[ -z "$p" ]] && continue
    pf="${REPO_ROOT}/${p}"
    [[ -f "${pf}" ]] || { log "::error title=Patch not found::${pf}"; exit 1; }
    log "::group::Applying ${p}"
    apply_one_patch "${tree}" "${pf}" || { log "::error title=Patch failed::${p}"; exit 1; }
    log "::endgroup::"
  done
  popd >/dev/null
}

sync_aufs_sources() {
  local tree=$1
  local dest_dir="${tree}/fs/aufs"
  rm -rf "${dest_dir}"
  mkdir -p "${tree}/fs"
  cp -a "${REPO_ROOT}/fs/aufs" "${tree}/fs/"
  mkdir -p "${tree}/include/uapi/linux"
  cp -a "${REPO_ROOT}/include/uapi/linux/aufs_type.h" "${tree}/include/uapi/linux/"
}

setup_compiler() {
  [[ "${COMPILER}" == "clang" ]] || return
  local required_major=15 clang_bin="" clang_major=""
  if command -v clang >/dev/null 2>&1; then
    clang_major=$(clang --version | sed -n '1s/.*version \([0-9]\+\).*/\1/p')
    [[ -n "${clang_major}" && ${clang_major} -ge ${required_major} ]] && clang_bin=$(command -v clang)
  fi
  if [[ -z "${clang_bin}" ]]; then
    local candidate
    for candidate in $(seq 20 -1 ${required_major}); do
      if command -v "clang-${candidate}" >/dev/null 2>&1; then clang_bin=$(command -v "clang-${candidate}"); break; fi
    done
  fi
  [[ -n "${clang_bin}" ]] || { echo "::error title=Missing clang::Need clang ${required_major}+ for kernel build" >&2; exit 1; }
  export LLVM=1
  if [[ "${clang_bin}" =~ clang-([0-9]+)$ ]]; then export LLVM_SUFFIX="-${BASH_REMATCH[1]}"; else unset LLVM_SUFFIX; fi
  export CC="${clang_bin}" HOSTCC="${clang_bin}"
  local hostcxx_candidate="clang++${LLVM_SUFFIX:-}"
  command -v "${hostcxx_candidate}" >/dev/null 2>&1 && export HOSTCXX="${hostcxx_candidate}"
  if [[ -n "${LLVM_SUFFIX:-}" && -x "$(command -v "ld.lld${LLVM_SUFFIX}")" ]]; then export LD="ld.lld${LLVM_SUFFIX}"; \
  elif command -v ld.lld >/dev/null 2>&1; then export LD=ld.lld; else unset LLVM CC LD; fi
}

wire_module_symvers() {
  local tree=$1
  pushd "${tree}" >/dev/null
  local kernelrel; kernelrel=$(make -s kernelrelease || true)

  # Priority 1: explicit path
  if [[ -n "${SYMVERS_FROM}" && -f "${SYMVERS_FROM}" ]]; then
    cp -f "${SYMVERS_FROM}" "${tree}/Module.symvers"
    echo "::notice Using Module.symvers from ${SYMVERS_FROM}"
    popd >/dev/null; return 0
  fi

  # Priority 2: matching release build dir
  local cand="/lib/modules/${kernelrel}/build/Module.symvers"
  if [[ -f "${cand}" ]]; then
    cp -f "${cand}" "${tree}/Module.symvers"
    echo "::notice Using Module.symvers from ${cand}"
    popd >/dev/null; return 0
  fi

  # Priority 3: current running kernel build dir
  cand="/lib/modules/$(uname -r)/build/Module.symvers"
  if [[ -f "${cand}" ]]; then
    cp -f "${cand}" "${tree}/Module.symvers"
    echo "::notice Using Module.symvers from ${cand}"
    popd >/dev/null; return 0
  fi

  # Priority 4: optionally generate (expensive)
  if [[ "${GENERATE_SYMVERS}" == "1" ]]; then
    echo "::notice Generating Module.symvers by building in-tree modules (this may take a while)"
    make -j"$(nproc)" modules
  fi
  popd >/dev/null
}

json_array_from_list() {
  local arr=("$@"); local out=""
  for e in "${arr[@]}"; do [[ -z "$e" ]] && continue; out+=$(printf '%s"%s"' "${out:+, }" "$e"); done
  printf '[%s]' "${out}"
}

main() {
  ensure_build_dependencies
  setup_compiler
  local tree; tree=$(fetch_kernel "${workdir}")
  mkdir -p "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}"
  apply_patches "${tree}"
  sync_aufs_sources "${tree}"
  prepare_kernel "${tree}"

  # Attach / generate Module.symvers if needed
  wire_module_symvers "${tree}"
  if grep -q '^CONFIG_MODVERSIONS=y' "${tree}/.config"; then
    if [[ ! -f "${tree}/Module.symvers" ]]; then
      if [[ "${STRICT_SYMVERS}" == "1" ]]; then
        echo "::error title=Missing Module.symvers::Target kernel has MODVERSIONS=y; provide SYMVERS_FROM or set GENERATE_SYMVERS=1" >&2
        exit 1
      else
        echo "::warning title=No Module.symvers::Module may not load on target with symbol versioning" >&2
      fi
    fi
  fi

  export AUFS_VFS_COMPAT_FLAGS="$(detect_vfs_compat_flags "${tree}")"

  # Build external module against chosen kernel tree
  pushd "${REPO_ROOT}" >/dev/null
  make KDIR="${tree}" clean
  make KDIR="${tree}" -j"$(nproc)" \
    EXTRA_CFLAGS="-I${REPO_ROOT}/include ${AUFS_VFS_COMPAT_FLAGS}" \
    fs/aufs/aufs.ko
  cp fs/aufs/aufs.ko "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/aufs.ko"
  popd >/dev/null

  # Optional: vermagic hint (if kmod/modinfo available)
  if command -v modinfo >/dev/null 2>&1; then
    modinfo -F vermagic "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/aufs.ko" \
      > "${ARTIFACT_ROOT}/${KERNEL_ID}/${COMPILER}/vermagic.txt" || true
  fi

  local patches_json; patches_json=$(json_array_from_list "${PATCH_LIST[@]}")
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
