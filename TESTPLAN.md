# Aya OS AUFS Validation Plan

## Scope

This plan exercises AUFS+SquashFS stacks with LayerControl and TimeLayer semantics on Aya OS kernels derived from the CI matrix. It covers functional correctness, performance, and stability before issuing a Go/No-Go recommendation.【F:Documentation/filesystems/aufs/README†L38-L80】

## Test Matrix

| Dimension | Values |
|-----------|--------|
| Kernels | 6.1 LTS, 6.6 LTS, 6.10 mainline, 6.12 rc, 6.14-atlant (Aya localversion), 6.17 integration head |
| Toolchains | GCC 13 (Debian), Clang 18 |
| Backends | AUFS (target), overlayfs (baseline comparator) |
| Storage | Multi-RO SquashFS (Aya system images), RW ext4/tmpfs layers |
| Namespaces | Host, userns-rootless, chroot/initramfs |

CI ensures the module builds for each kernel/toolchain combination; runtime testing uses the same matrix but prioritises Aya shipping kernels first.【F:.github/workflows/build.yml†L1-L180】

## Functional Tests

1. **xfstests/generic subset** — run `generic/001`, `generic/013`, `generic/035`, `generic/313` with AUFS and overlayfs to validate rename, whiteout, seekdir, and link semantics. Capture diff vs overlayfs to spot behavioural regressions.【F:Documentation/filesystems/aufs/README†L38-L80】
2. **Branch manipulation** — use `tools/unionctl` to mount layered stacks, then add/remove/reorder branches while processes hold open descriptors. Validate via sysfs branch tables and file content checks.【F:tools/unionctl†L1-L400】【F:fs/aufs/opts.c†L640-L720】
3. **Copy-up semantics** — cover copy-up on open, move policy, and pseudo-hardlinks by creating files across RW/RW and RW/RO boundaries, ensuring inode persistence via `stat -c %i`. Leverage design notes for expected behaviour.【F:Documentation/filesystems/aufs/design/05wbr_policy.txt†L1-L120】
4. **Whiteout/opaqueness** — toggle `AUFS_SHWH`, verify `ls`/`find` visibility, and ensure whiteouts vanish after branch removal.
5. **Namespace flows** — mount under `chroot`, `pivot_root` in initramfs, and rootless `userns` when `allow_userns=1`. Confirm `FS_USERNS_MOUNT` propagation and failure behaviour when disabled.【F:fs/aufs/module.c†L148-L213】
6. **Inotify/Fanotify & LSM** — run AppArmor/SELinux default profiles, observe event delivery for copy-up rename storms. Compare overlayfs vs AUFS notification gaps.

## Performance Benchmarks

1. **Metadata storm** — measure `fs_mark` or custom `tests/mkmeta.py` to create/remove 50k small files; collect `ops/sec`. Focus on SquashFS lower depth 10+ for copy-up stress.
2. **Read latency** — use `fio --rw=randread` across long lowerdir chains (≥40) to characterise path lookup caching. Compare to overlayfs.
3. **Copy-up hot paths** — record `perf record -e sched:sched_switch` around `unionctl add-branch` triggered copy-up sequences; compute 95th percentile latencies.
4. **Branch migration** — evaluate `unionctl reorder` (AUFS remount) vs overlayfs remount cycle to feed LayerControl heuristics. Record downtime in milliseconds.

Perf counters are captured via `perf stat` and `bpftrace` scripts stored in `tests/perf/`. The initial smoke harness in `tests/smoke.sh` produces quick telemetry for CI sanity.【F:tests/smoke.sh†L1-L200】

## Stability & Longevity

1. **Soak** — run metadata storm + copy-up workloads for 24h, monitor slab usage via `/proc/slabinfo` and AUFS caches to detect leaks.【F:fs/aufs/module.c†L48-L120】
2. **Layer stress** — mount 512 SquashFS layers + 2 RW layers using `max-branches` preset; cycle add/remove to validate index rollover.
3. **Rename storms** — spawn 32 threads performing `renameat2()` across branches; watch for lockdep warnings (requires `lockdep-debug.patch`).
4. **Fail injection** — trigger lower branch faults (read-only toggles, forced `EIO`) and ensure AUFS aborts single syscalls without corrupting upper layers.【F:Documentation/filesystems/aufs/README†L38-L80】

## Success Criteria

* Functional parity with overlayfs across targeted xfstests.
* Copy-up and metadata performance within ±5% of current Aya AUFS baselines; overlayfs deltas captured for context.
* No slab leaks or kernel warnings across 24h soak.
* `unionctl` covers mount/add/del/reorder/list for AUFS and overlayfs with zero unexpected remount interruptions.
* Documentation (`docs/ADMIN.md`, `AYA-INTEGRATION.md`) updated with tuning guidance; QA scripts reproducible via `make smoke` alias.

## Reporting

* Store raw logs under `logs/` with timestamped filenames.
* Summarise metrics in `AYA-REPORT.md` including Go/No-Go decision and mitigation backlog.
* Attach strace/perf flamegraphs for regressions, linked from the report.
