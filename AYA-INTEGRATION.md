# Aya OS AUFS Integration Guide

## Initramfs Boot Flow

1. **Prepare Layers**
   * Mount immutable SquashFS images under `/run/aya/lower.d/*` in ascending priority order (oldest base first, newest overlay last).
   * Stage the writable state volume (ext4/F2FS) under `/run/aya/rw/current` and ensure journal replay completes before union mounting.
   * Optionally stage a volatile tmpfs layer for crash-only experimentation (`/run/aya/rw/volatile`).
2. **Generate AUFS config**
   * Use `tools/auconf --preset release --force` at image build time; switch to `debug` for troubleshooting rescue images.【F:tools/auconf†L12-L191】
   * Export the chosen preset via `/etc/aya/aufs.conf` to keep LayerControl/TimeLayer consistent.
3. **Mount Union**
   * Invoke `tools/unionctl mount --backend aufs --target /sysroot --branch /run/aya/rw/current=rw --branch /run/aya/lower.d/latest=ro --branch ...` inside initramfs.
   * Verify the mount via `/proc/mounts` and `/sys/fs/aufs/si_*/br*` when `brs=1`.
4. **Handoff**
   * Bind-mount `/sysroot` into the new root, move ephemeral control directories (LayerControl sockets, logs) before `switch_root`.

## LayerControl Hooks

* Use `unionctl add-branch --index 1` to splice hotfix SquashFS layers without service interruption; remount semantics reuse AUFS' `br=` parser for atomic updates.【F:tools/unionctl†L1-L400】【F:fs/aufs/opts.c†L640-L720】
* Monitor branch health via `/sys/fs/aufs/si_X/brY` — stale entries imply failed copy-up or permission issues. Emit health probes to Aya's watchdog.
* When detaching a branch, flush cached dentries with `echo 3 > /proc/sys/vm/drop_caches` only after AUFS confirms branch removal to avoid page cache thrash.

## TimeLayer Snapshots

* Model writable layers as rotate-able timelines: `current`, `snapshot.N`, `rescue`. Use AUFS' multiple RW branch support to promote snapshots atomically (remount with `unionctl reorder`).【F:Documentation/filesystems/aufs/README†L52-L74】
* For crash recovery, mount snapshots read-only and reattach the last known good branch as RW while preserving previous branch for forensic analysis.
* Ensure copy-up policies prefer the most recent RW layer (set `unionctl mount --policy=rr` once AUFS ioctl counterpart lands; until then rely on default move policy).【F:Documentation/filesystems/aufs/design/05wbr_policy.txt†L1-L120】

## Failure Handling

* **Missing lower layer** — abort boot with a descriptive error, fall back to overlayfs baseline using `unionctl --backend overlay --dry-run` to validate fallback plan.
* **RW corruption** — remount with `snapshot.N` as RW and mark the broken volume for later `fsck`; TimeLayer should queue a repair job.
* **User namespace mounts** — disable `allow_userns` unless Aya's sandbox explicitly requires it; enabling flips `FS_USERNS_MOUNT` for the filesystem type at registration.【F:fs/aufs/module.c†L148-L213】
* **LSM integration** — load AppArmor profiles before the AUFS mount so that copy-up inherits expected labels. Use `unionctl list --format json` to feed audit logs into Aya's telemetry bus.【F:tools/unionctl†L1-L400】

## Logging & Telemetry

* Keep `brs=1` to expose per-branch stats, but disable in production builds where sysfs exposure is restricted.
* When debugging, set `CONFIG_AUFS_DEBUG=y` via `tools/auconf --preset debug` and toggle runtime verbosity with `echo 1 > /sys/module/aufs/parameters/debug` (maps to the atomic module parameter).【F:fs/aufs/debug.c†L35-L83】
* Ship `logs/` artefacts from smoke/soak runs with Aya OTA packages to track regression trends.

Adhering to this flow ensures Aya OS can swap between AUFS and overlayfs with minimal churn while preserving recovery semantics.
