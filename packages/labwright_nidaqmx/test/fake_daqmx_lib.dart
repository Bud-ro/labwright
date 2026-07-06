// Compiles the C shim (test/native/fake_daqmx.c) into a shared library at test time
// and exposes its `fake_last_*` capture getters. Loading this via FfiDaqmxBackend
// exercises the real FFI marshalling path; the getters let tests assert exactly what
// crossed the C boundary. Returns null (-> tests self-skip) when no C toolchain is
// available or on Windows (different build flags).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Builds the shim once and caches the resulting library path (null if unbuildable).
String? buildFakeDaqmxLib() {
  if (_cached != null) return _cached;
  if (Platform.isWindows) return null; // cc -shared flags differ; covered elsewhere
  final src = _locateSource();
  if (src == null) return null;
  final cc = _firstOnPath(const ['cc', 'clang', 'gcc']);
  if (cc == null) return null;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  final dir = Directory.systemTemp.createTempSync('fake_daqmx');
  final out = '${dir.path}/libfake_daqmx.$ext';
  final r = Process.runSync(cc, ['-shared', '-fPIC', '-O0', '-o', out, src]);
  if (r.exitCode != 0) {
    // Surface compiler errors rather than silently skipping a broken shim.
    throw StateError('failed to build fake_daqmx: ${r.stderr}');
  }
  return _cached = out;
}

String? _cached;

String? _locateSource() {
  // dart test runs from the workspace root or the package dir; try both.
  const rel = 'test/native/fake_daqmx.c';
  for (final base in const ['packages/labwright_nidaqmx/', '']) {
    final f = File('$base$rel');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

String? _firstOnPath(List<String> names) {
  for (final n in names) {
    final r = Process.runSync('sh', ['-c', 'command -v $n']);
    if (r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty) return n;
  }
  return null;
}

/// Reads the shim's captured-argument getters (the same loaded image the backend
/// uses, since dlopen of one path is process-wide).
class FakeDaqmxProbe {
  FakeDaqmxProbe(String path) : _lib = DynamicLibrary.open(path);
  final DynamicLibrary _lib;

  double get lastAiMin => _d('fake_last_ai_min');
  double get lastAiMax => _d('fake_last_ai_max');
  int get lastAiTerm => _i('fake_last_ai_term');
  int get lastAiUnits => _i('fake_last_ai_units');
  String get lastChannel =>
      _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('fake_last_chan')().toDartString();
  double get lastWriteValue => _d('fake_last_write_value');
  double get lastWriteTimeout => _d('fake_last_write_timeout');
  int get lastWriteAutoStart => _i('fake_last_write_autostart');
  double get lastRate => _d('fake_last_rate');
  int get lastSampleMode => _i('fake_last_sample_mode');
  int get lastInputBuffer => _lib.lookupFunction<Uint32 Function(), int Function()>('fake_last_input_buffer')();

  double _d(String s) => _lib.lookupFunction<Double Function(), double Function()>(s)();
  int _i(String s) => _lib.lookupFunction<Int32 Function(), int Function()>(s)();
}
