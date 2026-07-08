import 'dart:math';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

const _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

/// Minimal big-endian RSRC (.vi): 32-byte header stored twice, five-u32 sub-header whose 4th word
/// points at the block list (0x34), u32 block count, 12 bytes per block entry, trailing Pascal name.
Uint8List _buildVi({
  String fileType = 'LVIN',
  List<String> blocks = const ['CONP', 'BDHb', 'vers'],
  String name = 'demo.vi',
}) {
  void be16(BytesBuilder b, int v) => b.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
  void be32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v)).buffer.asUint8List());

  final header = BytesBuilder()..add(_magic);
  be16(header, 3);
  header
    ..add(fileType.codeUnits)
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

/// The core invariant: `parseVi` is TOTAL — for ANY bytes it either returns a usable [ViSummary] or
/// throws [ViFormatException]. Anything else would crash the viewer on a real internet VI.
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
  test('parses header, block inventory, capability flags, and name; deterministic', () {
    final vi = parseVi(_buildVi());
    expect((vi.isVi, vi.creator, vi.formatVersion, vi.name), (true, 'LBVW', 3, 'demo.vi'));
    expect(vi.blocks, ['CONP', 'BDHb', 'vers']);
    expect((vi.hasConnectorPane, vi.hasBlockDiagram, vi.hasFrontPanel, vi.hasSubViLinks), (true, true, false, false));

    final full = _buildVi(blocks: const ['FPHb', 'BDHb', 'CONP', 'LIvi'], name: 'top.vi');
    final v2 = parseVi(full);
    expect((v2.hasFrontPanel, v2.hasSubViLinks), (true, true));
    expect(v2.describe(), contains('sub-VI links'));
    expect(parseVi(full).toJson(), parseVi(full).toJson(), reason: 'deterministic for a given input');
  });

  test('rejects non-RSRC and truncated files', () {
    expect(() => parseVi(Uint8List(64)), throwsA(isA<ViFormatException>()));
    expect(() => parseVi(Uint8List.fromList(_magic)), throwsA(isA<ViFormatException>()));
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
      final b = Uint8List(6 + rng.nextInt(2048));
      b.setRange(0, 6, _magic);
      for (var j = 6; j < b.length; j++) {
        b[j] = rng.nextInt(256);
      }
      _mustBeTotal(b);
    }
  });

  test('bit-flips and random u32 overwrites of a valid VI fail cleanly', () {
    final valid = _buildVi();
    final rng = Random(7);
    for (var i = 0; i < 20000; i++) {
      final b = Uint8List.fromList(valid);
      final muts = 1 + rng.nextInt(6);
      for (var m = 0; m < muts; m++) {
        if (rng.nextBool() && b.length >= 4) {
          ByteData.sublistView(b).setUint32(rng.nextInt(b.length - 3), rng.nextInt(0xFFFFFFFF));
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
      final b = Uint8List.fromList(_buildVi());
      final view = ByteData.sublistView(b);
      view.setUint32(16, extremes[rng.nextInt(extremes.length)]);
      for (var k = 0; k < 3; k++) {
        final at = rng.nextInt(b.length ~/ 4) * 4;
        if (at + 4 <= b.length) view.setUint32(at, extremes[rng.nextInt(extremes.length)]);
      }
      _mustBeTotal(b);
    }
  });

  test('valid VI with many blocks + megabytes of trailing garbage stays total + fast', () {
    final rng = Random(13);
    final base = _buildVi(blocks: [for (var i = 0; i < 5000; i++) 'B${(i % 100).toString().padLeft(3, '0')}']);
    final big =
        (BytesBuilder()
              ..add(base)
              ..add(Uint8List.fromList([for (var i = 0; i < 2 * 1024 * 1024; i++) rng.nextInt(256)])))
            .toBytes();
    final sw = Stopwatch()..start();
    _mustBeTotal(big);
    expect(sw.elapsedMilliseconds, lessThan(2000), reason: 'parser should not hang on big files');
  });

  test('every truncation of a valid VI fails cleanly', () {
    final valid = _buildVi();
    for (var cut = 0; cut <= valid.length; cut++) {
      _mustBeTotal(Uint8List.sublistView(valid, 0, cut));
    }
  });
}
