// Runtime-free tests: these do NOT require NI-DAQmx to be installed, so they pass
// in CI and on dev boxes. End-to-end behavior against a real runtime is validated
// separately on a Windows/Linux machine with NI-DAQmx (see README).

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:test/test.dart';

void main() {
  group('DaqmxVal constants match the documented NI-DAQmx C API', () {
    test('values', () {
      // Same canonical DAQmx_Val_* integers the qdaq backend uses — a typo here
      // would silently misconfigure real hardware.
      expect(DaqmxVal.cfgDefault, -1);
      expect(DaqmxVal.rse, 10083);
      expect(DaqmxVal.nrse, 10078);
      expect(DaqmxVal.diff, 10106);
      expect(DaqmxVal.pseudoDiff, 12529);
      expect(DaqmxVal.volts, 10348);
      expect(DaqmxVal.rising, 10280);
      expect(DaqmxVal.falling, 10171);
      expect(DaqmxVal.finiteSamps, 10178);
      expect(DaqmxVal.contSamps, 10123);
      expect(DaqmxVal.groupByChannel, 0);
      expect(DaqmxVal.groupByScanNumber, 1);
    });
  });

  group('runtime loading', () {
    test('open() either loads the runtime or throws NidaqmxUnavailable — never a raw error', () {
      // On macOS, or any host without the NI-DAQmx runtime (CI, this dev box), the
      // loader must fail cleanly with NidaqmxUnavailable, not an opaque FFI crash.
      // Where the runtime IS present, open() succeeds — both outcomes are acceptable.
      try {
        final ni = Nidaqmx.open();
        expect(ni.bindings, isNotNull);
      } on NidaqmxUnavailable catch (e) {
        expect(e.message, isNotEmpty);
      }
    });

    test('a bogus explicit path throws (not silently succeeds)', () {
      expect(() => Nidaqmx.open(path: '/nonexistent/libnidaqmx.so'), throwsA(anything));
    });
  });
}
