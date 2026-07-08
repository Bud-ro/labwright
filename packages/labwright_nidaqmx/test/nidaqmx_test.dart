// Runtime-free tests: no NI-DAQmx, gRPC server, or hardware required. The gRPC
// wire path is covered in grpc_backend_test.dart against an in-process fake.
import 'dart:io' show Platform;

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('DaqmxVal constants match the documented NI-DAQmx C API values', () {
    // A typo here would silently misconfigure real hardware.
    // dart format off
    const vals = <(String, int, int)>[
      ('cfgDefault', DaqmxVal.cfgDefault, -1), ('rse', DaqmxVal.rse, 10083), ('nrse', DaqmxVal.nrse, 10078),
      ('diff', DaqmxVal.diff, 10106), ('pseudoDiff', DaqmxVal.pseudoDiff, 12529), ('volts', DaqmxVal.volts, 10348),
      ('rising', DaqmxVal.rising, 10280), ('falling', DaqmxVal.falling, 10171),
      ('finiteSamps', DaqmxVal.finiteSamps, 10178), ('contSamps', DaqmxVal.contSamps, 10123),
      ('groupByChannel', DaqmxVal.groupByChannel, 0), ('groupByScanNumber', DaqmxVal.groupByScanNumber, 1),
      ('boolTrue', DaqmxVal.boolTrue, 1), ('boolFalse', DaqmxVal.boolFalse, 0),
    ];
    // dart format on
    for (final (name, got, want) in vals) {
      expect(got, want, reason: name);
    }
  });

  group('Daqmx.local() — transport selection', () {
    test('macOS has no local transport; elsewhere it yields the FFI backend', () {
      if (Platform.isMacOS) {
        expect(Daqmx.local, throwsA(isA<UnsupportedError>()));
      } else {
        expect(Daqmx.local(), isA<FfiDaqmxBackend>());
      }
    }, testOn: '!browser');

    test('construction is lazy — the runtime is only needed on first call', () async {
      if (Platform.isMacOS) return; // covered above
      final daq = Daqmx.local(); // must not throw even with no runtime installed
      try {
        expect(await daq.deviceNames(), isA<List<String>>());
      } on DaqmxUnavailable catch (e) {
        expect(e.message, isNotEmpty, reason: 'no runtime fails cleanly, never an opaque crash');
      }
      await daq.close();
    }, testOn: '!browser');

    test('a bogus explicit library path fails on use as DaqmxUnavailable', () async {
      if (Platform.isMacOS) return;
      final daq = Daqmx.local(libraryPath: '/nonexistent/libnidaqmx.so');
      await expectLater(daq.deviceNames(), throwsA(isA<DaqmxUnavailable>()));
    }, testOn: '!browser');

    test('using the FFI backend after close() throws StateError', () async {
      if (Platform.isMacOS) return;
      final daq = Daqmx.local();
      await daq.close();
      await expectLater(daq.deviceNames(), throwsA(isA<StateError>()));
    }, testOn: '!browser');
  });

  group('Daqmx.remote() — gRPC backend construction', () {
    test('yields a gRPC backend with NI\'s default port, without connecting', () {
      final daq = Daqmx.remote(host: 'localhost');
      expect(daq, isA<GrpcDaqmxBackend>());
      expect((daq as GrpcDaqmxBackend).port, 31763);
      expect(daq.secure, isFalse);
    });

    test('secure: true is carried onto the backend', () {
      expect((Daqmx.remote(host: 'localhost', secure: true) as GrpcDaqmxBackend).secure, isTrue);
    });
  });

  group('logging namespaces', () {
    test('all DaqLoggers descend from the package root', () {
      expect(DaqLoggers.root.fullName, 'labwright.nidaqmx');
      for (final l in [DaqLoggers.ffi, DaqLoggers.grpc, DaqLoggers.task, DaqLoggers.io]) {
        expect(l.fullName, startsWith('labwright.nidaqmx.'));
      }
    });

    test('the package never installs handlers or sets levels (host owns config)', () {
      expect(DaqLoggers.root.level, Logger.root.level);
    });
  });
}
