# Labwright

Open, cross-platform, Dart-based building blocks for end-to-end hardware test
automation — a clean-room alternative to the NI LabVIEW/TestStand stack. Tests
are plain **Dart code** (no DSL), measurement data stays in NI's **TDMS** format,
and legacy LabVIEW **`.vi`** files are read (not required).

> **Pruned to the foundation.** The repo was trimmed to the clean-room readers
> and the TDMS library — the parts that are independently validated. Earlier
> speculative scaffolding (a test engine, DAQ HAL, runner, traceability, fuzzing,
> a CLI) was removed; the owned NI-DAQmx Dart wrapper lives on its own branch/PR.
> Work continues in small, reviewable PRs.

## Packages

| Package | What it is | Validation |
|---------|------------|------------|
| [`packages/labwright_vi_parse`](packages/labwright_vi_parse) | Clean-room LabVIEW **`.vi` / `.ctl` / `.llb`** (RSRC) reader — container + block parse, heap decode → object graph / VI→IR | parses **435 real-world VIs**; fuzz-proven total (any bytes → summary or clean error) |
| [`packages/labwright_teststand`](packages/labwright_teststand) | Clean-room NI **TestStand `.seq`** reader — XML/INI typed model + binary `TOF1` recon | 26 XML files / 33 sequences / 214 steps; corpus-driven |
| [`packages/labwright_tdms`](packages/labwright_tdms) | NI **TDMS** reader/writer + CSV / summary / diff / merge utilities | validated against real LabVIEW files; fuzz-hardened |

Two Flutter inspector apps (`apps/labwright_vi_inspector`,
`apps/labwright_teststand_inspector`) and an [`example/e2e`](example/e2e)
authoring sketch round out the tree. Each package carries its own README and the
BSD-3-Clause `LICENSE`.

## Develop

Requires Dart `>=3.11`. The packages share one native [pub workspace](pubspec.yaml).

```sh
dart pub get                 # resolves the whole workspace
dart analyze --fatal-infos   # clean
dart test                    # run per package, e.g.:
dart test packages/labwright_vi_parse
```

## License

BSD-3-Clause — see [LICENSE](LICENSE).
