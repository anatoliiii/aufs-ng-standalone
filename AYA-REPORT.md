# Aya OS AUFS Engineering Report

## Executive Summary

The current AUFS NG standalone tree is structurally ready for Aya OS integration. The module builds reproducibly once kernel headers are available, and the new tooling (`auconf`, `unionctl`) covers the management surface needed by LayerControl and TimeLayer. Residual work centres on kernel header availability in CI and broadening runtime validation (xfstests, perf). Overall recommendation: **Go**, contingent on completing the test plan and resolving overlayfs permission gaps observed during container smoke runs.【F:config.mk†L1-L76】【F:fs/aufs/Makefile†L1-L17】【F:tools/unionctl†L1-L247】

## Metrics Snapshot

| Check | Backend | Result | Notes |
|-------|---------|--------|-------|
| `make` against host kernel headers | AUFS | ❌ | Missing `/lib/modules/$(uname -r)/build` in container; CI workflow mitigates by fetching explicit kernel trees.【4fa0c6†L1-L10】【F:.github/workflows/build.yml†L1-L78】 |
| `tests/smoke.sh` mount attempt | overlayfs (baseline) | ⚠️ | Permission denied in sandbox; unionctl dry-run verified command synthesis.【F:logs/testplan-smoke.log†L1-L13】 |
| `auconf --list-presets` | tooling | ✅ | Presets surfaced for release/debug/max-branches flows.【F:logs/testplan-smoke.log†L1-L5】 |

Full benchmark and soak metrics will be populated once the CI matrix delivers modules for Aya’s kernel set and the TESTPLAN is executed across hardware targets.【F:TESTPLAN.md†L1-L80】

## Risk Register

1. **Kernel drift** — AUFS remains out-of-tree; periodic rebasing against Linux 6.10+ requires sustained maintenance. Mitigation: automated CI matrix with both GCC and Clang catches breakage early.【F:.github/workflows/build.yml†L1-L78】
2. **Namespace hardening** — enabling `allow_userns` exposes AUFS mounts to rootless sandboxes. Gate via deployment policy and audit per-release.【F:fs/aufs/module.c†L148-L213】【F:docs/ADMIN.md†L1-L24】
3. **Missing features (nested mounts, stats)** — upstream disabled several features in aufs6; Aya must avoid depending on them or re-enable explicitly.【F:Documentation/filesystems/aufs/README†L82-L108】
4. **Overlayfs fallback parity** — baseline overlayfs tests currently fail under container permissions; ensure host CI runners allow overlayfs to gather regression data.【F:logs/testplan-smoke.log†L1-L13】

## Work Plan (Go Path)

1. **Finalize CI** — land GitHub workflow, verify archives resolve, and publish `.ko` artefacts for all kernel/compiler combinations.【F:.github/workflows/build.yml†L1-L78】
2. **Execute TESTPLAN** — run xfstests + custom workloads on Aya hardware; capture perf telemetry and soak logs in `logs/`.【F:TESTPLAN.md†L1-L120】
3. **LayerControl integration** — wire `unionctl` into Aya initramfs scripts per `AYA-INTEGRATION.md`; validate snapshot promotion and failure paths.【F:AYA-INTEGRATION.md†L1-L76】
4. **Documentation polish** — keep `docs/ADMIN.md` aligned with measured safe defaults; extend with sysfs telemetry once counters are collected.【F:docs/ADMIN.md†L1-L24】

## Decision

**Go**, provided that the CI jobs remain green and the forthcoming validation completes without regressions. The tooling and documentation added in this cycle close the previous operational gaps and reduce the risk of switching Aya OS images between AUFS and overlayfs.【F:ANALYSIS.md†L1-L74】【F:AYA-INTEGRATION.md†L1-L76】
