// Runtime-free tests: these do NOT require NI-DAQmx, a gRPC server, or any hardware,
// so they pass in CI and on dev boxes. The gRPC wire path is covered separately in
// grpc_backend_test.dart against an in-process fake server.

import 'dart:io' show Platform;

import 'package:labwright_nidaqmx/labwright_nidaqmx.dart';
import 'package:logging/logging.dart';
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
      final daq = Daqmx.remote(host: 'localhost', secure: true) as GrpcDaqmxBackend;
      expect(daq.secure, isTrue);
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
      // A library that configures logging fights its host. We only create loggers.
      expect(DaqLoggers.root.level, Logger.root.level);
    });
  });
}
