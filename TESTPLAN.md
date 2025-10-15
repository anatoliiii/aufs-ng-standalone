# План валидации AUFS для Aya OS

## Охват

План проверяет связку AUFS+SquashFS с семантикой LayerControl и TimeLayer на ядрах Aya из CI-матрицы. Мы покрываем корректность, производительность и стабильность перед выдачей решения Go/No-Go.【F:Documentation/filesystems/aufs/README†L38-L80】

## Матрица тестов

| Измерение | Значения |
|-----------|----------|
| Ядра | 6.1 LTS, 6.6 LTS, 6.10 mainline, 6.12 rc, 6.14-atlant (Aya localversion), 6.17 integration head |
| Компиляторы | GCC 13 (Debian), Clang 18 |
| Бэкенды | AUFS (целевой), overlayfs (базовый для сравнения) |
| Хранилища | Набор RO SquashFS (системные образы Aya), RW ext4/tmpfs слои |
| Namespaces | Host, userns-rootless, chroot/initramfs |

CI гарантирует сборку модуля под каждую комбинацию ядра и компилятора; runtime-тестирование использует ту же матрицу, но приоритет — релизные ядра Aya.【F:.github/workflows/build.yml†L1-L180】

## Функциональные тесты

1. **xfstests/generic subset** — прогнать `generic/001`, `generic/013`, `generic/035`, `generic/313` для проверки rename, whiteout, seekdir и link-семантики. Фиксируем дифф относительно overlayfs, чтобы заметить расхождения.【F:Documentation/filesystems/aufs/README†L38-L80】
2. **Манипуляции ветками** — через `tools/unionctl` монтируем стеки, затем добавляем/удаляем/переставляем ветки при открытых файловых дескрипторах. Проверяем sysfs-таблицы веток и содержимое файлов.【F:tools/unionctl†L1-L400】【F:fs/aufs/opts.c†L640-L720】
3. **Семантика copy-up** — покрываем copy-up on open, политику move и псевдо-hardlink: создаём файлы через границы RW/RW и RW/RO, проверяя номера inode через `stat -c %i`. Сверяемся с дизайн-документом.【F:Documentation/filesystems/aufs/design/05wbr_policy.txt†L1-L120】
4. **Whiteout/opaqueness** — переключаем `AUFS_SHWH`, следим за видимостью через `ls`/`find`, убеждаемся, что whiteout исчезает после удаления ветки.
5. **Namespace-сценарии** — монтируем под `chroot`, `pivot_root` в initramfs и rootless `userns` при `allow_userns=1`. Подтверждаем распространение `FS_USERNS_MOUNT` и корректные отказы при выключенном параметре.【F:fs/aufs/module.c†L148-L213】
6. **Inotify/Fanotify и LSM** — запускаем базовые профили AppArmor/SELinux, отслеживаем доставку событий при rename storm. Сравниваем с overlayfs.

## Производительные тесты

1. **Шторм метаданных** — `fs_mark` или `tests/mkmeta.py` создаёт/удаляет 50k мелких файлов; собираем `ops/sec`. Акцент на глубине нижних слоёв SquashFS ≥10 для нагрузки на copy-up.
2. **Задержка чтения** — `fio --rw=randread` по длинным цепочкам lowerdir (≥40), чтобы оценить кеширование путей. Сравниваем с overlayfs.
3. **Горячие copy-up** — `perf record -e sched:sched_switch` вокруг copy-up, вызванных `unionctl add-branch`; считаем 95-й перцентиль латентности.
4. **Миграция веток** — сравниваем `unionctl reorder` (перемонт AUFS) с циклом перемонтирования overlayfs. Фиксируем простой в миллисекундах.

Счётчики снимаются через `perf stat` и скрипты `bpftrace` в `tests/perf/`. Smoke-харнес `tests/smoke.sh` даёт быструю телеметрию для CI.【F:tests/smoke.sh†L1-L200】

## Стабильность и длительные прогоны

1. **Soak** — комбинируем шторм метаданных и copy-up в течение 24 часов, мониторим slab через `/proc/slabinfo` и кеши AUFS, чтобы выявить утечки.【F:fs/aufs/module.c†L48-L120】
2. **Стресс по слоям** — монтируем 512 слоёв SquashFS + 2 RW-ветки, используя пресет `max-branches`; циклически добавляем/удаляем ветки, проверяя корректность индексации.
3. **Rename storm** — 32 потока выполняют `renameat2()` через ветки; следим за предупреждениями lockdep (патч `lockdep-debug.patch`).
4. **Инъекция сбоев** — симулируем ошибки нижних веток (перевод в RO, принудительный `EIO`) и убеждаемся, что AUFS завершает отдельные системные вызовы без порчи верхних слоёв.【F:Documentation/filesystems/aufs/README†L38-L80】

## Критерии успеха

* Функциональный паритет с overlayfs по целевым xfstests.
* Copy-up и метаданные не хуже ±5% относительно текущих базовых AUFS в Aya; дельты overlayfs фиксируются для контекста.
* Отсутствие утечек slab и предупреждений ядра за 24 часа soak.
* `unionctl` покрывает mount/add/del/reorder/list для AUFS и overlayfs без неожиданных перемонтажей.
* Документация (`docs/ADMIN.md`, `AYA-INTEGRATION.md`) содержит актуальные рекомендации; QA-скрипты воспроизводимы через alias `make smoke`.

## Отчётность

* Храните сырые логи в `logs/` с временными метками.
* Сводите метрики в `AYA-REPORT.md`, включая решение Go/No-Go и бэклог мер.
* Прикладывайте strace/perf-флеймграфы для регрессий, с ссылками из отчёта.
