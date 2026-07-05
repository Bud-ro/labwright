/// `e2e_test` — the bench-team extension layer of the labwright example.
///
/// `package:labwright` is the runner: `test()` registers named bodies from
/// an `e2e/main.dart`, they run one at a time after `main` returns, and
/// `expect(...)` decides pass/fail. This library shows what a bench team
/// layers ON TOP of that surface without touching the runner: [e2eTest]
/// hands the body a [Dut] (device under test) that carries instrument
/// [Plug]s, named [Dut.phase]s, and limit-checked [Dut.measure]ments; each
/// reading is [log]ged as it is checked, the run passes iff every
/// measurement lands inside its limit, and the [TestRecord] serialises to
/// TDMS — the same traceable artifact the legacy NI stack produced,
/// written from plain Dart.
///
/// Nothing here talks to real hardware: a [Plug] is an interface, and the
/// example implements it in-memory so the suite runs in CI. Swapping in a
/// bench driver that implements [Plug] is the only change needed on real
/// hardware.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:labwright/labwright.dart';
import 'package:labwright_tdms/labwright_tdms.dart';

export 'package:labwright_tdms/labwright_tdms.dart' show TdmsReader, TdmsFile;

/// Whether a run met every limit ([pass]) or not ([fail]).
enum Outcome { pass, fail }

/// A physical quantity with a unit symbol, used to build [Limit]s that read
/// naturally at the call site: `volts.within(3.3, 0.1)`, `amps.between(0, 2)`.
class Unit {
  const Unit(this.symbol);

  /// The unit symbol recorded alongside a measurement (e.g. `V`, `A`).
  final String symbol;

  /// A limit of `nominal ± tolerance`.
  Limit within(double nominal, double tolerance) =>
      Limit(nominal - tolerance, nominal + tolerance, this);

  /// A limit of `[min, max]`, inclusive.
  Limit between(double min, double max) => Limit(min, max, this);

  /// A lower bound (no upper limit).
  Limit atLeast(double min) => Limit(min, double.infinity, this);

  /// An upper bound (no lower limit).
  Limit atMost(double max) => Limit(double.negativeInfinity, max, this);
}

const volts = Unit('V');
const amps = Unit('A');
const ohms = Unit('Ω');
const degreesC = Unit('°C');

/// An inclusive numeric range a measured value must fall in to pass.
class Limit {
  const Limit(this.min, this.max, this.unit);

  final double min;
  final double max;
  final Unit unit;

  /// Whether [value] is within `[min, max]`.
  bool accepts(double value) => value >= min && value <= max;

  // 3.3 - 0.1 is 3.1999999999999997; the log line should read 3.2.
  static String _fmt(double v) =>
      v.isFinite ? num.parse(v.toStringAsPrecision(10)).toString() : '$v';

  @override
  String toString() => '[${_fmt(min)}, ${_fmt(max)}] ${unit.symbol}';
}

/// An instrument or fixture a [Dut] drives — the end-to-end analogue of an
/// OpenHTF "plug". Real benches implement this over a DAQ/SCPI/USB transport;
/// the examples implement it in-memory.
abstract interface class Plug {}

/// One limit-checked reading taken during a run.
class Measurement {
  Measurement(
    this.phase,
    this.name,
    this.value,
    this.limit, {
    this.requirement,
  });

  /// The [Dut.phase] this reading was taken in.
  final String phase;

  /// The measurement's name (becomes its TDMS channel).
  final String name;

  /// The measured value.
  final double value;

  /// The limit it was checked against.
  final Limit limit;

  /// The requirement id this reading covers, if any.
  final String? requirement;

  /// Whether the reading met its limit.
  bool get inLimit => limit.accepts(value);
}

/// The result of one device run: its measurements, outcome, and the set of
/// requirements it covered. Serialises to TDMS — one channel per measurement,
/// grouped by phase, with units/outcome/requirement as channel properties —
/// so the rest of the toolchain consumes runs exactly as it did NI output.
class TestRecord {
  TestRecord(this.dutId, this.measurements);

  /// The device-under-test id (e.g. a serial number).
  final String dutId;

  /// Every reading taken, in order.
  final List<Measurement> measurements;

  /// [Outcome.pass] iff every measurement met its limit.
  Outcome get outcome =>
      measurements.every((m) => m.inLimit) ? Outcome.pass : Outcome.fail;

  /// The distinct requirement ids this run covered.
  Set<String> get requirements => {
        for (final m in measurements)
          if (m.requirement != null) m.requirement!,
      };

  /// Encodes the run as a single-segment TDMS file (one channel per
  /// measurement, grouped by phase). Round-trips through [TdmsReader].
  Uint8List toTdmsBytes() {
    final channels = [
      for (final m in measurements)
        TdmsChannel(
          group: m.phase,
          name: m.name,
          data: [m.value],
          properties: {
            'units': m.limit.unit.symbol,
            'outcome': m.inLimit ? 'pass' : 'fail',
            if (m.requirement != null) 'requirement': m.requirement!,
          },
        ),
    ];
    return (TdmsWriter()
          ..writeSegment(
            channels,
            fileProperties: {'dutId': dutId, 'outcome': outcome.name},
          ))
        .toBytes();
  }
}

/// The device under test handed to an [e2eTest] body: it holds the plugs, the
/// current phase, and the accumulating [record].
class Dut {
  Dut(this.id);

  /// The device-under-test id for this run.
  final String id;

  final List<Measurement> _measurements = [];
  String _phase = 'main';

  /// Registers and returns an instrument/fixture [Plug] for use in the body.
  P use<P extends Plug>(P plug) => plug;

  /// Runs a named phase; measurements taken inside [body] are tagged [name].
  Future<void> phase(String name, FutureOr<void> Function() body) async {
    final previous = _phase;
    _phase = name;
    try {
      await body();
    } finally {
      _phase = previous;
    }
  }

  /// Records a limit-checked [value]. A reading outside [limit] fails the run.
  void measure(String name, double value, Limit limit, {String? requirement}) {
    _measurements.add(
      Measurement(_phase, name, value, limit, requirement: requirement),
    );
  }

  /// The run so far, as a [TestRecord].
  TestRecord get record => TestRecord(id, List.unmodifiable(_measurements));
}

/// Runs [body] against a fresh [Dut] and returns its [TestRecord] — the core
/// without the [test] wrapper, for when you want the record directly (e.g.
/// to assert a TDMS round-trip).
Future<TestRecord> runDevice(
  String dutId,
  FutureOr<void> Function(Dut) body,
) async {
  final dut = Dut(dutId);
  await body(dut);
  return dut.record;
}

/// Declares a hardware end-to-end test on the labwright runner — layered
/// over [test], so it registers like any other test and its body runs after
/// `main` returns. The run passes iff every measurement lands inside its
/// limit, and any id in [requirements] must actually be measured or the
/// test fails as uncovered. [requirements] also bind to the labwright
/// requirements trace (the run report), and every reading is [log]ged as
/// it is checked — visible in the terminal and the live viewer.
///
/// labwright has no expected-failure tier (exceptions ARE failures), so
/// proving a fault is CAUGHT is written as a normal passing test that
/// asserts the reading falls OUTSIDE its limit — see the brownout example.
void e2eTest(
  String description,
  FutureOr<void> Function(Dut) body, {
  List<String> requirements = const [],
  String? dutId,
}) {
  test(description, requirements: requirements, () async {
    final record = await runDevice(dutId ?? description, body);
    for (final m in record.measurements) {
      log('${m.phase} · ${m.name} = ${m.value} ${m.limit.unit.symbol}, '
          'limit ${m.limit}${m.inLimit ? '' : ' — OUT'}');
    }
    expect(
      record.outcome,
      Outcome.pass,
      reason: 'readings: '
          '${record.measurements.map((m) => '${m.name}=${m.value}${m.inLimit ? '' : ' OUT'}').join(', ')}',
    );
    for (final req in requirements) {
      expect(
        record.requirements,
        contains(req),
        reason: 'declared requirement $req was never measured',
      );
    }
  });
}
