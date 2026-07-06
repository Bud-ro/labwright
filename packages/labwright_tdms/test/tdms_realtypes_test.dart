import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// Builds a single-segment TDMS file with arbitrary channel types, endianness,
/// and interleaving — to exercise the reader's real-world paths deterministically
/// (no external sample files). dtype: 3=I32, 6=U16, 10=Double.
Uint8List _buildTdms({
  required Endian endian,
  required bool interleaved,
  required List<({String path, int dtype, List<num> values})> chans,
}) {
  void put(BytesBuilder b, int v, int bytes, {bool float = false}) {
    final d = ByteData(8);
    if (float) {
      d.setFloat64(0, v.toDouble(), endian);
    } else if (bytes == 2) {
      d.setUint16(0, v, endian);
    } else {
      d.setInt32(0, v, endian);
    }
    b.add(d.buffer.asUint8List(0, bytes));
  }

  void u32(BytesBuilder b, int v, Endian e) {
    final d = ByteData(4)..setUint32(0, v, e);
    b.add(d.buffer.asUint8List());
  }

  void u64(BytesBuilder b, int v, Endian e) {
    final d = ByteData(8)..setUint64(0, v, e);
    b.add(d.buffer.asUint8List());
  }

  void str(BytesBuilder b, String s, Endian e) {
    final u = utf8.encode(s);
    u32(b, u.length, e);
    b.add(u);
  }

  void elem(BytesBuilder b, int dtype, num v) {
    switch (dtype) {
      case 3:
        put(b, v.toInt(), 4);
      case 6:
        put(b, v.toInt(), 2);
      case 10:
        put(b, v.toInt(), 8, float: true);
    }
  }

  final meta = BytesBuilder();
  u32(meta, chans.length, endian);
  for (final c in chans) {
    str(meta, c.path, endian);
    u32(meta, 20, endian);
    u32(meta, c.dtype, endian);
    u32(meta, 1, endian);
    u64(meta, c.values.length, endian);
    u32(meta, 0, endian);
  }

  final raw = BytesBuilder();
  if (interleaved) {
    final n = chans.first.values.length;
    for (var s = 0; s < n; s++) {
      for (final c in chans) {
        elem(raw, c.dtype, c.values[s]);
      }
    }
  } else {
    for (final c in chans) {
      for (final v in c.values) {
        elem(raw, c.dtype, v);
      }
    }
  }

  final metaB = meta.toBytes();
  final rawB = raw.toBytes();
  final out = BytesBuilder()..add(Uint8List.fromList([0x54, 0x44, 0x53, 0x6D]));
  var toc = (1 << 1) | (1 << 2) | (1 << 3);
  if (endian == Endian.big) toc |= 1 << 6;
  if (interleaved) toc |= 1 << 5;
  u32(out, toc, Endian.little);
  u32(out, 4713, endian);
  u64(out, metaB.length + rawB.length, endian);
  u64(out, metaB.length, endian);
  out
    ..add(metaB)
    ..add(rawB);
  return out.toBytes();
}

void main() {
  test('reads an Int32 channel (little-endian)', () {
    final f = TdmsReader.read(
      _buildTdms(
        endian: Endian.little,
        interleaved: false,
        chans: [
          (path: "/'g'/'i'", dtype: 3, values: [-5, 0, 7, 2147483647]),
        ],
      ),
    );
    expect(f.group('g')!.channel('i')!.data, [-5.0, 0.0, 7.0, 2147483647.0]);
  });

  test('reads a big-endian U16 channel', () {
    final f = TdmsReader.read(
      _buildTdms(
        endian: Endian.big,
        interleaved: false,
        chans: [
          (path: "/'g'/'u'", dtype: 6, values: [0, 1, 65535, 1000]),
        ],
      ),
    );
    expect(f.group('g')!.channel('u')!.data, [0.0, 1.0, 65535.0, 1000.0]);
  });

  test('reads interleaved channels (sample-major)', () {
    final f = TdmsReader.read(
      _buildTdms(
        endian: Endian.little,
        interleaved: true,
        chans: [
          (path: "/'g'/'a'", dtype: 3, values: [1, 2, 3]),
          (path: "/'g'/'b'", dtype: 3, values: [10, 20, 30]),
        ],
      ),
    );
    expect(f.group('g')!.channel('a')!.data, [1.0, 2.0, 3.0]);
    expect(f.group('g')!.channel('b')!.data, [10.0, 20.0, 30.0]);
  });
}
