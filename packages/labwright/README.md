# labwright

The Labwright E2E test API and runner. Bundles a CLI + Web Server for watching test execution and (re)running tests.

```
dart pub global activate --source path packages/labwright   # (pub.dev later)
labwright init          # generate an example e2e/ test folder
labwright run           # Run E2E tests. Equivalent to dart run e2e/main.dart
labwright scan          # list files with tests not plugged into main.dart
```

## Test Structure

Tests may be placed anywhere, but by convention the `e2e/` folder is the typical location for tests,
inside of which a top-level `main.dart` registers tests. `dart run e2e/main.dart` may be used directly
but the `labwright` executable offers additional conveniences. After the completion of `main`, the test
suite will begin running.

It's recommended to define a synchronous `register` function for each conceptually related group
of tests, and then place a call to it from `e2e/main.dart`.

```dart
// e2e/main.dart
import 'power_rail_test.dart' as power_rail;

Future<void> main() async {
  // Code can be run at the top level before registering any tests.
  await pinMap.load('OutputVoltage.pinmap');

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

## Semantics and Features

- A call to `test()` registers its body with the framework. Bodies run
  after every test is registered (when `main` finishes), one at a time.
- Tests pass if they return or reach the end of the body without throwing
  an Error or exception.
- The `package:test` API works directly. This is possible by running each body under 
  a `test_api` case. Additionally the `expect`, `expectLater`, `fail`, `TestFailure`, 
  and every matcher are re-exported.
- `test()` cases may be provided with a `requirement[s]`. External tooling may consume this
  via the generated reports.
- As a test runs, by default nothing is output. The labwright `log('...')` function allows
  for printing messages to the CLI and web viewer.
- `button('label', () async { ... })`, registered alongside `test()`, adds an operator
  control to the interactive viewer — a bench action (e.g. `Reset unit`) the user fires on
  demand. The action runs serialized with test runs, streams its `log()` lines, and is
  viewer-only (it never runs under a plain `dart run`/CI pass).

## Configuration

See `labwright --help` for how to configure a test suite run. If instead the test suite 
is run using `dart run e2e/main.dart`, then these flags may be provided to `dart run`:

| define / flag | meaning |
|---|---|
| `-Dlabwright.seed=N` | Seed affecting test ordering, and allows for reproducible runs. Printed at run start. Affects labwright randomness APIs as well. |
| `-Dlabwright.totalShards=N -Dlabwright.shardIndex=I` | Allows for distributing tests across runners. Always uses a fixed seed unless specified. |
| `-Dlabwright.port=N` | viewer port (default 1212, "LAB" : L=12, A=1, B=2) |
| `-Dlabwright.viewer=false` | Prevents the viewer from launching |
| `-Dlabwright.keepOpen=true` OR `-Dlabwright.interactive=true` | Keep serving results after the run, and allow for tests to be (re)-run |
| `-Dlabwright.identity=false` | Skip the report's content-identity hashes (~3s hasher isolate, off the bench path); hot reload then conservatively re-runs everything |
| `-Dlabwright.report=out.json` | Write a JSON report (tests, statuses, logs, requirements trace, seed, summary) |

The interactive viewer is a full-screen app with three panes on screen at once, each with its own filter:
a compact **Tests** pane (latest-run status, jump-to-source, a ▶ queue button), a **Queue** pane (what is
waiting to run), and a large scrollable **Log** pane — an animated history of every execution with its logs,
newest at top. Everything is **timestamped** in your local time — when a test was queued, started, and
finished, and when each log line was emitted. A test's `log` button spotlights its latest run in the Log
pane. Across the top you can re-run all/failed/one test, stop after the current test, fire operator
`button()`s, **open a test's source** in VS Code (a plain `vscode://` link — from a Windows browser it
opens Windows VS Code, including into a WSL suite), **download** the JSON report or **copy** failures. Each
test badges its run-to-run change — `new fail`, `now passing`, and `flaky` (a test that keeps flipping verdict).

Every viewer control is one `POST /<verb>` with a JSON body (`{}` when the verb takes no arguments),
served only under `--interactive`/`--keep-open` (503 otherwise) and only for same-origin
`application/json` requests (403 otherwise): 202 accepted, 409 rejected, 404 unknown verb.

| route | body | effect |
|---|---|---|
| `POST /run` | | re-run all selected tests |
| `POST /run-failed` | | re-run the currently failing tests |
| `POST /run-one` | `{"test": "<name>"}` | run one test |
| `POST /stop` | | stop after the current test |
| `POST /reload` | | hot reload, then re-run the modified tests |
| `POST /restart` | | hot restart (needs the `labwright run` supervisor) |
| `POST /reseed` | `{"seed": N}` | re-shuffle to a seed and re-run |
| `POST /button` | `{"index": i}` | fire an operator `button()` |

**Hot reload** reloads edited sources and **re-runs only the modified tests** (`labwright run
--interactive` starts the VM service for this; running `dart run` directly needs
`--enable-vm-service`). Modification is detected by content hash: an edit inside one test's body re-runs
just that test, while an edit to shared setup/helpers conservatively re-runs everything. **Reload's honest
limit:** a registered test body is a *captured closure*, and a VM reload cannot re-map an already-captured
closure — so code reached *through functions your tests call* reloads reliably, but an edit made directly
inside a test's inline body runs its OLD code, and added/removed tests don't appear.

**Hot restart** is the full-fidelity answer: the suite exits with a restart sentinel and the `labwright
run` supervisor spawns a fresh process — fresh registration, new captures, every edit real. The viewer
page survives (the connection dot goes red, then green as the stream reconnects on the same port) and the
fresh suite runs from the top. Requires the CLI supervisor; under a bare `dart run` the button explains
why it is disabled. With `--port 0` the fresh process binds a NEW ephemeral port, so use a fixed port
(the default 1212 is fine) when you want restart.

## Content identity (skip-unmodified tooling)

The report factors "did anything change?" into three SHA-1 hashes so external tooling can skip tests whose
inputs are provably unchanged — a prior verdict is reusable only while **all three** match:

| report field | covers |
|---|---|
| per-test `hash` | that test's `test(...)` registration call — name, requirements, body — as a token stream (formatting/comments don't shift it) |
| `setupHash` | every file reachable from the entry script via local imports, with all test bodies factored *out* — shared setup and helpers |
| `contextHash` | the bench-declared `context` map — what is physically under test |

Labwright cannot know what is on the bench, so the suite declares it during setup:

```dart
context('dut.serial', await dut.serialNumber());
context('dut.firmware', await dut.firmwareVersion());
```

Caveats, stated honestly: the walk follows relative imports only (sources imported by `package:` URI are
not covered by `setupHash`); a test registered through a tear-off or wrapper has no attributable call site
and carries **no** `hash` — consumers must treat an absent hash as "assume modified"; and hashes reflect
the sources as loaded, so a disk edit without a hot reload does not change what the report claims ran.

## TestStand Converter

The structure of sequences from a TestStand `.seq` file can be directly converted into Labwright
compatible structure using `labwright_seq`'s `exportSeqFileToLabwright` (or
`dart run tool/export_dart.dart file.seq out.dart --e2e`). Each **root** sequence 
becomes one `lw.test` whose `requirements:` unions every link the test reaches. Called sequences
become plain functions, with steps as lines of code. VI calls get stub functions, and every other 
unported surface is an inline `throw UnimplementedError(...)` naming its target. Tests
containing any ship as `lw.skipTest` with a TODO list.
