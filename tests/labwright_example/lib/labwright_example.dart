/// A worked example: a power-supply (PSU) board test.
///
/// This is the canonical reference for authoring a Labwright test — phases that
/// drive a DAQ peripheral, measurements with limits, and requirement references
/// for traceability. Run it with `bin/psu.dart`; the same [psuTest] is exercised
/// by `test/psu_test.dart` against a [SimulatedDaq].
library;

import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_daq/labwright_daq.dart';
import 'package:labwright_traceability/labwright_traceability.dart';

/// The requirements this test verifies (mirrors a hashed requirements.json).
Map<String, RequirementSpec> psuRequirements() => parseRequirements([
      {'id': 'REQ-PWR-001', 'hash': 'a1', 'text': '3V3 rail within 3.2-3.4 V'},
      {'id': 'REQ-PWR-002', 'hash': 'b2', 'text': '5V rail within 4.9-5.1 V'},
      {'id': 'REQ-ID-001', 'hash': 'c3', 'text': 'DUT reports a serial number SNxxxx'},
    ]);

/// A simulated PSU DUT: healthy rails by default. Pass [faultyRail5v] to model a
/// 5 V brownout (for demos and regression).
SimulatedDaq demoPsuDaq({bool faultyRail5v = false}) => SimulatedDaq(analogInputs: {
      0: Signals.constant(3.31), // 3V3 rail
      1: Signals.constant(faultyRail5v ? 4.2 : 4.98), // 5V rail
    });

/// The PSU board test, parameterized by the DAQ it talks to (inject a real
/// backend on the bench, or [SimulatedDaq] for hardware-free runs).
Test psuTest(SimulatedDaq daq, {String serial = 'SN0042'}) => Test(
      'psu-board',
      [
        Phase('power on', (ctx) async {
          await ctx.peripheral<SimulatedDaq>().analogOut(0).write(1.0); // assert ENABLE
          ctx.log('asserted ENABLE');
        }),
        Phase('rail 3v3', (ctx) async {
          final v = await ctx.peripheral<SimulatedDaq>().analogIn(0).read();
          ctx
              .measure<num>('rail_3v3',
                  units: 'V',
                  validators: [Validators.inRange(3.2, 3.4)],
                  requirements: [const RequirementRef('REQ-PWR-001', hash: 'a1')])
              .value = v;
        }),
        Phase('rail 5v', (ctx) async {
          final v = await ctx.peripheral<SimulatedDaq>().analogIn(1).read();
          ctx
              .measure<num>('rail_5v',
                  units: 'V',
                  validators: [Validators.inRange(4.9, 5.1)],
                  requirements: [const RequirementRef('REQ-PWR-002', hash: 'b2')])
              .value = v;
        }),
        Phase('serial', (ctx) async {
          ctx
              .measure<String>('serial',
                  validators: [Validators.matches(RegExp(r'^SN\d+$'))],
                  requirements: [const RequirementRef('REQ-ID-001', hash: 'c3')])
              .value = serial;
        }),
      ],
      peripherals: {'daq': daq},
    );
