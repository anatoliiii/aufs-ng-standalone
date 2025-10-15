# AUFS NG Standalone — Code & Build Map

## Repository Topology

* `fs/aufs` — kernel module sources organised by subsystem: superblock glue (`super.c`, `sbinfo.c`), branch management (`branch.c`, `opts.c`), copy-up/whiteout engines (`cpup.c`, `whout.c`), inode/dentry layers (`iinfo.c`, `dinfo.c`), and optional features gated by `CONFIG_AUFS_*`. The `Makefile` enumerates all compilation units and handles conditional inclusion for xattr, exportfs, FHSM, poll, and debug helpers.【F:fs/aufs/Makefile†L1-L35】
* `include/uapi/linux/aufs_type.h` — public ABI for userspace helpers such as `mount.aufs` and tooling integrated via `make install_headers`.【F:Makefile†L38-L54】
* Top-level `Makefile` orchestrates out-of-tree builds by pointing at `${KDIR}`, injecting `EXTRA_CFLAGS`, and driving kernel header installation alongside module compilation.【F:Makefile†L1-L54】
* Patch series (`aufs6-*.patch`, `tmpfs-idr.patch`, `vfs-ino.patch`, etc.) capture delta against vanilla kernels and are consumed by CI automation when preparing Aya kernel drops.

## Build & Configuration Flow

1. `make` resolves `${KDIR}` to the currently running kernel build directory, warning when configuration headers are missing — a common case when cross-compiling within containers.【F:Makefile†L1-L23】
2. `config.mk` injects AUFS-specific `CONFIG_` toggles which feed into `AUFS_DEF_CONFIG` and, in turn, the module build. The new `CONFIG_AUFS_DEBUG ?= n` stanza allows reproducible debug builds without forcing `-DDEBUG` globally.【F:config.mk†L1-L76】
3. `fs/aufs/Makefile` consumes `CONFIG_AUFS_DEBUG` to append `-DDEBUG` only when the flag is asserted, aligning with Aya's requirement for opt-in verbose logging.【F:fs/aufs/Makefile†L1-L17】
4. `tools/auconf` regenerates the configuration preamble while preserving the warning/validation logic in the tail of `config.mk`, letting CI capture mis-matched dependencies (e.g. SBILIST without PROC_FS).【F:tools/auconf†L12-L191】【F:config.mk†L34-L76】

## Capability Map

* **Branch management** — dynamic add/del/prepend/append operations flow through `opts.c` (`Opt_append`, `Opt_del`, `Opt_mod`) and the sysfs-backed state machine under `/sys/fs/aufs/si_*`, enabling LayerControl to reorder or prune branches without remounting.【F:fs/aufs/opts.c†L640-L720】
* **Copy-up policies** — writeback routing supports move/copy heuristics, sparse files, and whiteout optimisation as documented in `design/05wbr_policy.txt`, providing the necessary hooks for TimeLayer snapshots.【F:Documentation/filesystems/aufs/design/05wbr_policy.txt†L1-L120】
* **Pseudo-hardlinks & whiteouts** — README highlights branch permission flags, whiteout hardlinking, and pseudo-hardlink semantics, all critical for SquashFS + RW overlay correctness in Aya OS.【F:Documentation/filesystems/aufs/README†L38-L80】
* **User/ID namespaces** — `allow_userns` gate surfaces the `FS_USERNS_MOUNT` capability bit at registration time, allowing controlled rootless mounts when Aya enables it in constrained sandboxes.【F:fs/aufs/module.c†L148-L213】
* **Monitoring** — Debug builds wire `/sys/fs/aufs` statistics and optional debugfs exports, giving TimeLayer an inspection surface without reboots.【F:fs/aufs/debug.c†L35-L83】【F:fs/aufs/module.c†L148-L213】

## Runtime Tunables & Limits

* Module parameters (`brs`, `allow_userns`, `debug`, `sysrq`) map directly to Aya runtime controls; refer to `docs/ADMIN.md` for operational guidance.【F:fs/aufs/module.c†L148-L189】【F:fs/aufs/debug.c†L35-L83】【F:fs/aufs/sysrq.c†L96-L143】
* Branch limits default to 127 but scale up to 32k when `CONFIG_AUFS_BRANCH_MAX_32767` is enabled via the new `max-branches` preset — necessary for Aya's multi-squash image stacks.【F:config.mk†L1-L32】【F:tools/auconf†L12-L191】
* SBILIST, DEBUGFS, and MAGIC_SYSRQ dependencies are validated at parse time; CI catches misconfigurations early because `config.mk` aborts the build when prerequisite kernel options are missing.【F:config.mk†L34-L76】

## Known Constraints & Risk Inventory

* Upstream rejection of AUFS remains; maintaining out-of-tree patches is unavoidable, and README documents the historical lack of mainline acceptance.【F:Documentation/filesystems/aufs/README†L17-L37】
* Nested mount support, statistics exports, and other experimental features are currently disabled in aufs6 per upstream TODOs, so Aya-specific extensions must not rely on them without re-enabling code paths.【F:Documentation/filesystems/aufs/README†L82-L108】
* NFS export is supported but historically fragile; we treat it as an opt-in scenario and document the risk in the Aya integration notes.【F:Documentation/filesystems/aufs/README†L52-L74】

## Build Prerequisites & Toolchain

* Requires kernel headers prepared via `make modules_prepare`; the standalone build fails fast if `/lib/modules/<version>/build` or `headers_install.sh` are missing, which is surfaced in the provided smoke log for transparency.【4fa0c6†L1-L10】
* Toolchain defaults to GCC but our CI matrix exercises both GCC and Clang against multiple kernel trees, ensuring Aya's Debian-based toolchains remain covered.【F:.github/workflows/build.yml†L1-L180】

The above map underpins the ensuing CI, testing, and integration artefacts and provides a baseline for estimating Aya OS specific effort.
