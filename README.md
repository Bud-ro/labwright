# Labwright

Open, cross-platform, Dart-based building blocks for end-to-end hardware test
automation — a clean-room alternative to the NI LabVIEW/TestStand stack. Tests
are plain **Dart code** (no DSL), measurement data stays in NI's **TDMS** format,
and legacy LabVIEW **`.vi`** files are read (not required).

> **Published incrementally.** The packages below are the foundational,
> independently-validated libraries. More — the DAQ hardware-abstraction layer,
> test runner, requirement traceability, DUT fuzzing, a unified CLI, and example
> Flutter apps — land in follow-up commits as they're validated.

## Packages

| Package | What it is | Validation |
|---------|------------|------------|
| [`packages/labwright_core`](packages/labwright_core) | Test engine: `Test` / `Phase` / `Peripheral` / `Measurement` (+ validators) / `TestRecord` / `Station` | unit + property tests |
| [`packages/labwright_tdms`](packages/labwright_tdms) | NI **TDMS** reader/writer + CSV / summary / diff / merge utilities | validated against real LabVIEW files; fuzz-hardened |
| [`packages/labwright_viparse`](packages/labwright_viparse) | Clean-room LabVIEW **`.vi` / `.ctl` / `.llb`** (RSRC) reader | parses **435 real-world VIs**; fuzz-proven total (any bytes → summary or clean error) |

Each package carries its own README and the BSD-3-Clause `LICENSE`.

## Develop

Requires Dart `>=3.11`. The packages share one native [pub workspace](pubspec.yaml).

```sh
dart pub get                 # resolves the whole workspace
dart analyze --fatal-infos   # clean
dart test                    # run per package, e.g.:
dart test packages/labwright_core
```

## License

BSD-3-Clause — see [LICENSE](LICENSE).
