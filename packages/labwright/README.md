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
instruments. An E2E file is therefore a **plain Dart program**:

```dart
import 'package:labwright/labwright.dart';

Future<void> main() async {
  await sequence('PowerRail', requirements: ['REQ-SEQ-1'], (s) async {
    await s.step('Rail comes up', requirement: 'REQ-1', (ctx) async {
      final v = await dmm.read();
      ctx.check(v > 3.0, '3.3V rail above 3.0V');
    });
  });
}
```

`dart run file.dart` already gives CI-meaningful exit codes; the `labwright`
runner adds aggregation across files, the live viewer, and reports.

## Status contract

- a false `ctx.check` **fails** the step; execution continues
  (continue-on-fail, as TestStand ran production floors);
- `ctx.pending(...)` or an escaped `UnimplementedError` marks the step
  **pending** — boilerplate awaiting an implementation (a VI-call stub), never
  a failure;
- any other escape is an **error**;
- exit code is non-zero iff something failed or errored — pending stays green
  (`--fail-on-pending` tightens CI).

## The runner

`labwright run [paths...]` executes each file via `dart run` with
`LABWRIGHT_REPORT=jsonl`, renders live progress, and:

- serves the **live viewer** at `http://localhost:8642` (`--port`, `0` picks a
  free port; `--keep-open` keeps serving after the run) — SSE-fed, single
  self-contained page;
- writes `--report out.json`: per-file sequences/steps plus the
  **requirements trace** (each requirement ID → every step claiming it, with
  status);
- exits non-zero for CI on failures/crashes (and pendings under
  `--fail-on-pending`).

## TestStand import

`labwright_seq`'s `exportSeqFileToLabwright` (or
`dart run tool/export_dart.dart file.seq out.dart --e2e`) converts a TestStand
`.seq` into this API: one `lw.sequence` per sequence, every step wrapped and
requirement-linked, VI calls stubbed (implement to arm), all other module
calls pending-by-name.
