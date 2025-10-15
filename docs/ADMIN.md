# AUFS Runtime Parameters

| Parameter | Default | Description | When to enable | Side effects |
|-----------|---------|-------------|----------------|--------------|
| `brs` | `1` | Exposes per-branch sysfs files under `/sys/fs/aufs/si_*/brN` for management tooling. | Keep enabled when sysfs-based branch control or observability is required (e.g. LayerControl). | Requires `CONFIG_SYSFS`; emits warnings if sbilist/sysrq expectations are not met.【F:fs/aufs/module.c†L148-L189】 |
| `allow_userns` | `false` | Allows unprivileged users inside user namespaces to mount AUFS instances. | Enable for rootless containers or Aya sandbox sandboxes that rely on user namespaces. | Increases attack surface; ensure the kernel has userns hardened appropriately.【F:fs/aufs/module.c†L156-L189】 |
| `debug` | `0` | Enables atomic toggle for verbose AUFS tracing through `pr_debug` hooks. | Combine with the `debug` preset in `tools/auconf` during deep kernel investigations. | High-volume logging; requires AUFS to be built with `CONFIG_AUFS_DEBUG=y` or the debug preset.【F:fs/aufs/debug.c†L35-L83】【F:fs/aufs/Makefile†L6-L27】 |
| `sysrq` | kernel default | Binds a magic SysRq trigger for AUFS emergency diagnostics. | Useful for bare-metal debugging; typically tied to Aya's serial-console escape hatch. | Only available when `CONFIG_MAGIC_SYSRQ` and `CONFIG_AUFS_DEBUG` are on; exposes kernel memory to operators.【F:fs/aufs/sysrq.c†L96-L143】【F:config.mk†L34-L76】 |

## Observability Hooks

* Sysfs surfaces branch tables, whiteout counters, and copy-up statistics when `brs=1` and `CONFIG_SYSFS` are enabled, permitting LayerControl to audit topology without parsing `/proc/mounts`.【F:fs/aufs/module.c†L148-L189】
* Debug builds expose `/sys/fs/aufs/debug` counters together with tracepoints; pair with `CONFIG_DEBUG_FS` for full coverage.【F:fs/aufs/debug.c†L35-L83】

## Recommended Presets

* **Release** — default shipped configuration, matching upstream behaviour with conservative branch count.
* **Debug** — `tools/auconf --preset debug --show` turns on tracing, sysrq, and `udba=*notify` prerequisites.【F:tools/auconf†L12-L191】
* **Max-branches** — `tools/auconf --preset max-branches --force` raises branch limits to 32k for extremely deep SquashFS stacks.【F:tools/auconf†L12-L191】

Use `tools/auconf --list-presets` to enumerate presets and `--show` to review the delta before committing configuration changes. Always regenerate `config.mk` under version control to keep CI reproducible.【F:tools/auconf†L12-L191】
