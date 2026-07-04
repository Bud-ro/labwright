# labwright

The labwright hardware E2E test API and CLI — the TestStand-replacement
execution surface. **One process, no IPC, no scanning.**

```
dart pub global activate --source path packages/labwright   # (pub.dev later)
labwright init          # generate the example e2e/ folder
labwright run           # = dart run -Dlabwright.*=... e2e/main.dart
labwright scan          # list test files not plugged into main.dart
```

## The convention

An `e2e/` folder with a top-level `main.dart` that every test module is
plugged into **by hand** — the suite IS `dart run e2e/main.dart`:

```dart
// e2e/main.dart
import 'power_rail_test.dart' as power_rail;

Future<void> main() async {
  await pinMap.load('OutputVoltage.pinmap'); // bench setup — before any test()
  power_rail.register();
}

// e2e/power_rail_test.dart
import 'package:labwright/labwright.dart';

void register() {
  test('output voltage in range', requirements: ['REQ-101'], () async {
    await psu.setVoltage(2.0);
    expect(await dmm.readVoltage(), inInclusiveRange(1.9, 2.1));
  });
}
```

Everything happens inside that single process: registration, sharding,
seeding, the live viewer, the report. `labwright run` spawns exactly one
`dart run` (flags map to `-Dlabwright.*` defines, SIGINT/SIGTERM forward so
nothing orphans) — and running the file yourself is always equivalent, with
zero child processes. `labwright scan` lints the convention: any `.dart`
file under `e2e/` not reachable from `main.dart` via imports is named and
the command exits 1, so CI can gate on forgotten tests.

## Semantics

- **Registration, then execution.** `test()` only registers; bodies run
  after every test is registered (when `main` finishes), one at a time —
  the bench is singular. Async setup goes before the first `test()`; a late
  registration throws a `StateError` rather than silently joining.
- **`package:test` assertions as-is.** `expect`, `expectLater`, `fail`,
  `TestFailure`, and every matcher are re-exported; each body runs inside a
  real `test_api` case, so failures and late async errors behave exactly as
  under `dart test`. **Exceptions are how tests fail**: `TestFailure` →
  failed, anything else → error, both exit non-zero. No soft-fail tier.
- `skipTest` = `test` with the body disarmed (reported, not run). Rename to
  arm. To-do notes are comments; there is no metadata for them.
- Requirement tracing IDs attach to tests (`requirement:`/`requirements:`)
  and land in the report's requirements trace.
- `log('...')` prints, attaches to the running test, and streams to the
  viewer.

## Configuration (defines, never env vars)

| define / flag | meaning |
|---|---|
| `-Dlabwright.seed=N` / `--seed N\|random` | shuffle run order deterministically; `0` = registration order; printed at the start of every test; exposed to bodies as `seed` (the future fuzz hook) |
| `-Dlabwright.totalShards=N -Dlabwright.shardIndex=I` / `--total-shards --shard-index` | run tests whose registration index ≡ I (mod N) — the in-process registry is the whole suite, so the modulo is global by construction; membership never depends on the seed |
| `-Dlabwright.port=N` / `--port` | viewer port (default 8642, `0` ephemeral) |
| `-Dlabwright.viewer=false` / `--no-viewer` | disable the viewer |
| `-Dlabwright.keepOpen=true` / `--keep-open` | keep serving results after the run |
| `-Dlabwright.report=out.json` / `--report` | write the machine-readable report (tests, statuses, logs, requirements trace, seed, summary) |

The **live viewer** runs in-process at `http://localhost:8642` — SSE-fed,
self-contained, the planned suite visible up front and each test's log lines
under it. A busy port warns and continues; a viewer must never fail a
hardware run.

## TestStand import

`labwright_seq`'s `exportSeqFileToLabwright` (or
`dart run tool/export_dart.dart file.seq out.dart --e2e`) converts a TestStand
`.seq` into this API: each **root** sequence becomes one `lw.test` whose
`requirements:` unions every link the test reaches; called sequences stay
plain functions; steps are just lines of code. VI calls get stub functions
(implement to port); every other unported surface is an inline
`throw UnimplementedError(...)` naming its target, and a test still
containing any ships disarmed as `lw.skipTest` with a TODO list — rename to
arm. Exported programs are standalone suites; plug them into `e2e/main.dart`
like any other module or run them directly.
