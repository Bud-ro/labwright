# labwright

The labwright hardware E2E test API and runner — the TestStand-replacement
execution surface.

```
dart pub global activate --source path packages/labwright   # (pub.dev later)
labwright run e2e/ --report run.json
```

## Why not `dart test`

Hardware E2E owns the bench: files run strictly one at a time, in order, in
their own process, with no sharding/isolation layer between the test and the
instruments. An E2E file is therefore a **plain Dart program** — setup is
ordinary code at the top of `main`, a test is a named body of ordinary code:

```dart
import 'package:labwright/labwright.dart';

Future<void> main() async {
  await pinMap.load('OutputVoltage.pinmap'); // setup — before any test()

  test('output voltage in range', requirements: ['REQ-101'], () async {
    await psu.setVoltage(2.0);
    final v = await dmm.readVoltage();
    expect(v, inInclusiveRange(1.9, 2.1));
  });
}
```

**Registration, then execution.** `test()` only registers; bodies run after
every test is registered (when `main` finishes). Async setup goes before the
first `test()`; a registration arriving after the run starts throws a
`StateError` rather than silently joining.

**Collect, then run.** Like `integration_test`, the runner invokes each file
twice: a collect pass (`-Dlabwright.mode=collect` — registrations reported,
no body runs; note `main`'s setup code executes both times) gathers the
whole ordered suite, then each file runs exactly the tests the runner chose
(`-Dlabwright.tests=…`), in the chosen order. All configuration travels as
Dart defines (`-D`) — no environment variables. Convention: E2E files live
in an `e2e/` folder; `labwright run` scans it (or takes explicit files).

The `package:test` assertion surface works **as-is** — `expect`,
`expectLater`, `fail`, `TestFailure`, and every matcher are re-exported, and
each body runs inside a real `test_api` case (the third-party-runner hooks),
so failure descriptions and late async errors behave exactly as under
`dart test`.

## Semantics

- **Exceptions are how tests fail.** A `TestFailure` (what `expect` throws)
  reports *failed*; any other escape reports *error*; both exit non-zero.
  There is no soft-fail tier.
- **Registration order is execution order**, one body at a time — the bench
  is singular. Register from `main` or any function `main` reaches.
- `skipTest` = `test` with the body disarmed (reported, not run). Rename to
  arm. To-do notes are comments; there is no metadata for them.
- Requirement tracing IDs attach to tests (`requirement:`/`requirements:`)
  and flow into the report's requirements trace.
- `log('...')` lines attribute to the running test and stream to the viewer.

## The runner

`labwright run [paths...]` (default `e2e/`) collects, then executes each
file via `dart run`, renders live progress, and:

- serves the **live viewer** at `http://localhost:8642` (`--port`, `0` picks a
  free port; `--keep-open` keeps serving after the run) — SSE-fed, single
  self-contained page, with each test's log lines under it;
- writes `--report out.json`: per-file tests plus the **requirements trace**
  (each requirement ID → every test claiming it, with status);
- shards with `--total-shards N --shard-index I` (`dart test`'s
  convention): of the collected suite, a test runs in shard `I` iff its
  global index is `≡ I (mod N)` — a plain modulo over one list, one bench
  per shard, and for any N the shards exactly partition the suite;
- randomizes run order with `--seed N` (`random` mints one): the selected
  tests shuffle deterministically; the seed is printed at the start of
  every test, carried in the report, and exposed to bodies as `seed` — the
  hook fuzz testing will grow from. `0` (default) = collected order;
- exits non-zero for CI on failures/errors/crashes (and skips under
  `--fail-on-skipped` — generated boilerplate ships as `skipTest`).

## TestStand import

`labwright_seq`'s `exportSeqFileToLabwright` (or
`dart run tool/export_dart.dart file.seq out.dart --e2e`) converts a TestStand
`.seq` into this API: each **root** sequence (one nothing else calls) becomes
one `lw.test` whose `requirements:` unions every link the test reaches;
called sequences stay plain functions; steps are just lines of code. VI calls
get stub functions (implement to port); every other unported surface is an
inline `throw UnimplementedError(...)` naming its target, and a test that
still contains any ships disarmed as `lw.skipTest` with a TODO list — rename
to arm.
