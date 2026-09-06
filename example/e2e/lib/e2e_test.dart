import 'dart:async';
import 'dart:typed_data';

import 'package:labwright/labwright.dart';
import 'package:labwright_tdms/labwright_tdms.dart';

export 'package:labwright_tdms/labwright_tdms.dart' show TdmsReader, TdmsFile;

enum Outcome { pass, fail }

class Unit {
  const Unit(this.symbol);

  final String symbol;

  Limit within(double nominal, double tolerance) => Limit(nominal - tolerance, nominal + tolerance, this);

  Limit between(double min, double max) => Limit(min, max, this);

  Limit atLeast(double min) => Limit(min, double.infinity, this);

  Limit atMost(double max) => Limit(double.negativeInfinity, max, this);
}

const volts = Unit('V');
const amps = Unit('A');
const ohms = Unit('Ω');
const degreesC = Unit('°C');

class Limit {
  const Limit(this.min, this.max, this.unit);

  final double min;
  final double max;
  final Unit unit;

  bool accepts(double value) => value >= min && value <= max;

  static String _fmt(double v) => v.isFinite ? num.parse(v.toStringAsPrecision(10)).toString() : '$v';

  @override
  String toString() => '[${_fmt(min)}, ${_fmt(max)}] ${unit.symbol}';
}

abstract interface class Plug {}

class Measurement {
  Measurement(
    this.phase,
    this.name,
    this.value,
    this.limit, {
    this.requirement,
  });

  final String phase;

  final String name;

  final double value;

  final Limit limit;

  final String? requirement;

  bool get inLimit => limit.accepts(value);
}

class TestRecord {
  TestRecord(this.dutId, this.measurements);

  final String dutId;

  final List<Measurement> measurements;

  Outcome get outcome => measurements.every((m) => m.inLimit) ? Outcome.pass : Outcome.fail;

  Set<String> get requirements => {
    for (final m in measurements)
      if (m.requirement != null) m.requirement!,
  };

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
    return (TdmsWriter()..writeSegment(
          channels,
          fileProperties: {'dutId': dutId, 'outcome': outcome.name},
        ))
        .toBytes();
  }
}

class Dut {
  Dut(this.id);

  final String id;

  final List<Measurement> _measurements = [];
  String _phase = 'main';

  P use<P extends Plug>(P plug) => plug;

  Future<void> phase(String name, FutureOr<void> Function() body) async {
    final previous = _phase;
    _phase = name;
    try {
      await body();
    } finally {
      _phase = previous;
    }
  }

  void measure(String name, double value, Limit limit, {String? requirement}) {
    _measurements.add(
      Measurement(_phase, name, value, limit, requirement: requirement),
    );
  }

  TestRecord get record => TestRecord(id, List.unmodifiable(_measurements));
}

Future<TestRecord> runDevice(
  String dutId,
  FutureOr<void> Function(Dut) body,
) async {
  final dut = Dut(dutId);
  await body(dut);
  return dut.record;
}

void e2eTest(
  String description,
  FutureOr<void> Function(Dut) body, {
  List<String> requirements = const [],
  String? dutId,
}) {
  test(description, requirements: requirements, () async {
    final record = await runDevice(dutId ?? description, body);
    for (final m in record.measurements) {
      log(
        '${m.phase} · ${m.name} = ${m.value} ${m.limit.unit.symbol}, '
        'limit ${m.limit}${m.inLimit ? '' : ' — OUT'}',
      );
    }
    expect(
      record.outcome,
      Outcome.pass,
      reason:
          'readings: '
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
