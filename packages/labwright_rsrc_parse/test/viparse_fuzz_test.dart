import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// A minimal valid RSRC (.vi) container (blocks CONP/BDHb/vers + a trailing name).
Uint8List _validVi({List<String> blocks = const ['CONP', 'BDHb', 'vers'], String name = 'demo.vi'}) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  final header = BytesBuilder()..add([0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
  be16(header, 3);
  header
    ..add('LVIN'.codeUnits)
    ..add('LBVW'.codeUnits);
  be32(header, 32);
  be32(header, 0);
  be32(header, 0x20);
  be32(header, 0);
  final headerBytes = header.toBytes();

  final info = BytesBuilder()..add(headerBytes);
  be32(info, 0);
  be32(info, 0);
  be32(info, 0x20);
  be32(info, 0x34);
  be32(info, 0);
  be32(info, blocks.length);
  for (final t in blocks) {
    info
      ..add(t.codeUnits)
      ..add([0, 0, 0, 0, 0, 0, 0, 0]);
  }
  info
    ..addByte(name.length)
    ..add(name.codeUnits);

  return (BytesBuilder()
        ..add(headerBytes)
        ..add(info.toBytes()))
      .toBytes();
}

/// The core invariant: `parseVi` is **total** — for ANY bytes it either returns a
/// usable [ViSummary] or throws [ViFormatException]. Anything else (RangeError,
/// StateError, a generic FormatException, OOM, …) is a bug that would crash the
/// viewer on a real internet VI, so we fail loudly with the offending input.
void _mustBeTotal(Uint8List b) {
  try {
    final s = parseVi(b);
    s
      ..describe()
      ..toJson();
    expect(s.blocks.length, lessThanOrEqualTo(100002));
  } on ViFormatException {
    // acceptable: a clean, catchable rejection
  } catch (e, st) {
    fail('parseVi leaked ${e.runtimeType} on ${b.length} bytes: $e\n$st');
  }
}

void main() {
  test('the valid VI parses (and keeps parsing after hardening)', () {
    final vi = parseVi(_validVi());
    expect(vi.blocks, ['CONP', 'BDHb', 'vers']);
    expect(vi.name, 'demo.vi');
    expect(vi.hasBlockDiagram, isTrue);
  });

  test('arbitrary random bytes (0..4KB) never crash the parser', () {
    final rng = Random(99);
    for (var i = 0; i < 20000; i++) {
      final n = rng.nextInt(i < 200 ? 40 : 4096);
      _mustBeTotal(Uint8List.fromList([for (var j = 0; j < n; j++) rng.nextInt(256)]));
    }
  });

  test('random bytes that start with the RSRC magic never crash', () {
    final rng = Random(5);
    for (var i = 0; i < 20000; i++) {
      final n = 6 + rng.nextInt(2048);
      final b = Uint8List(n);
      b.setRange(0, 6, const [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]);
      for (var j = 6; j < n; j++) {
        b[j] = rng.nextInt(256);
      }
      _mustBeTotal(b);
    }
  });

  test('bit-flips and random u32 overwrites of a valid VI fail cleanly', () {
    final valid = _validVi();
    final rng = Random(7);
    for (var i = 0; i < 20000; i++) {
      final b = Uint8List.fromList(valid);
      final muts = 1 + rng.nextInt(6);
      for (var m = 0; m < muts; m++) {
        if (rng.nextBool() && b.length >= 4) {
          final at = rng.nextInt(b.length - 3);
          ByteData.sublistView(b).setUint32(at, rng.nextInt(0xFFFFFFFF));
        } else {
          b[rng.nextInt(b.length)] = rng.nextInt(256);
        }
      }
      _mustBeTotal(b);
    }
  });

  test('extreme structural fields (huge offsets/counts) fail cleanly', () {
    final rng = Random(11);
    const extremes = [0, 1, 2, 0x20, 0x7f, 0x80, 0xffff, 0x7fffffff, 0xfffffffe, 0xffffffff];
    for (var i = 0; i < 20000; i++) {
      final b = Uint8List.fromList(_validVi());
      final view = ByteData.sublistView(b);
      view.setUint32(16, extremes[rng.nextInt(extremes.length)]);
      for (var k = 0; k < 3; k++) {
        final at = (rng.nextInt(b.length ~/ 4)) * 4;
        if (at + 4 <= b.length) view.setUint32(at, extremes[rng.nextInt(extremes.length)]);
      }
      _mustBeTotal(b);
    }
  });

  test('valid VI with many blocks + megabytes of trailing garbage stays total + fast', () {
    final rng = Random(13);
    final base = _validVi(blocks: [for (var i = 0; i < 5000; i++) 'B${(i % 100).toString().padLeft(3, '0')}']);
    final big = BytesBuilder()
      ..add(base)
      ..add(Uint8List.fromList([for (var i = 0; i < 2 * 1024 * 1024; i++) rng.nextInt(256)]));
    final sw = Stopwatch()..start();
    _mustBeTotal(big.toBytes());
    expect(sw.elapsedMilliseconds, lessThan(2000), reason: 'parser should not hang on big files');
  });

  test('every truncation of a valid VI fails cleanly', () {
    final valid = _validVi();
    for (var cut = 0; cut <= valid.length; cut++) {
      _mustBeTotal(Uint8List.sublistView(valid, 0, cut));
    }
  });

  test('parseVi is deterministic for a given input', () {
    final b = _validVi(blocks: const ['FPHb', 'BDHb', 'CONP', 'LIvi'], name: 'top.vi');
    expect(parseVi(b).toJson(), parseVi(b).toJson());
  });
}
