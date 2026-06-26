// Runtime-free tests: these do NOT require NI-DAQmx, a gRPC server, or any hardware,
// so they pass in CI and on dev boxes. End-to-end behavior against a real runtime /
// server is validated separately (see README).

import 'dart:io' show Platform;

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

  group('Daqmx.local() — transport selection', () {
    test('macOS has no local transport; elsewhere it yields the FFI backend', () {
      if (Platform.isMacOS) {
        // There is no local NI-DAQmx runtime on macOS, so a local connection is
        // impossible by construction — callers must use Daqmx.remote(...).
        expect(Daqmx.local, throwsA(isA<UnimplementedError>()));
      } else {
        expect(Daqmx.local(), isA<FfiDaqmxBackend>());
      }
    }, testOn: '!browser');

    test('construction is lazy — the runtime is only needed on first call', () async {
      if (Platform.isMacOS) return; // covered above
      final daq = Daqmx.local(); // must not throw even with no runtime installed
      // First real call either succeeds (runtime present) or fails cleanly with
      // DaqmxUnavailable — never an opaque crash.
      try {
        final names = await daq.deviceNames();
        expect(names, isA<List<String>>());
      } on DaqmxUnavailable catch (e) {
        expect(e.message, isNotEmpty);
      }
      await daq.close();
    }, testOn: '!browser');

    test('a bogus explicit library path fails on use, not on construction', () async {
      if (Platform.isMacOS) return;
      final daq = Daqmx.local(libraryPath: '/nonexistent/libnidaqmx.so');
      await expectLater(daq.deviceNames(), throwsA(anything));
    }, testOn: '!browser');
  });

  group('Daqmx.remote() — gRPC backend', () {
    test('yields a gRPC backend with NI\'s default port, without connecting', () {
      final daq = Daqmx.remote(host: 'localhost');
      expect(daq, isA<GrpcDaqmxBackend>());
      expect((daq as GrpcDaqmxBackend).port, 31763);
    });

    test('data-path methods are honestly pending (UnimplementedError, not a fake)', () {
      final daq = Daqmx.remote(host: 'localhost');
      expect(daq.deviceNames(), throwsA(isA<UnimplementedError>()));
    });
  });
}
