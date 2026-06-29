import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

/// Builds a single-segment DAQmx (format-changing scaler) TDMS file: int16
/// channels interleaved in one buffer of [stride] bytes, each at its byte offset.
/// Channel `a` carries a linear scale (slope/intercept, unscaled status); `b` does not.
Uint8List _buildDaqmx() {
  const stride = 4;
  final chans = [
    (path: "/'g'/'a'", offset: 0, raw: [10, 20, 30], scale: true),
    (path: "/'g'/'b'", offset: 2, raw: [-1, -2, -3], scale: false),
  ];

  void u32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(BytesBuilder b, int v) => b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void f64(BytesBuilder b, double v) => b.add((ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List());
  void str(BytesBuilder b, String s) {
    final u = utf8.encode(s);
    u32(b, u.length);
    b.add(u);
  }

  void prop(BytesBuilder b, String name, Object v) {
    str(b, name);
    if (v is String) {
      u32(b, 0x20);
      str(b, v);
    } else {
      u32(b, 10);
      f64(b, (v as num).toDouble());
    }
  }

  final meta = BytesBuilder();
  u32(meta, chans.length);
  for (final c in chans) {
    str(meta, c.path);
    u32(meta, 0x1269); // format-changing scaler index
    u32(meta, 0xFFFFFFFF); // overall data type
    u32(meta, 1); // dimension
    u64(meta, c.raw.length); // num values
    u32(meta, 1); // scaler count
    u32(meta, 3); // scaler data type code
    u32(meta, 0); // raw buffer index
    u32(meta, c.offset); // byte offset within stride
    u32(meta, 0); // sample format bitmap
    u32(meta, 0); // scale id
    u32(meta, 1); // width count
    u32(meta, stride); // raw data width (stride)
    if (c.scale) {
      u32(meta, 3); // property count
      prop(meta, 'NI_Scaling_Status', 'unscaled');
      prop(meta, 'NI_Scale[1]_Linear_Slope', 0.5);
      prop(meta, 'NI_Scale[1]_Linear_Y_Intercept', 1.0);
    } else {
      u32(meta, 0);
    }
  }

  final raw = BytesBuilder();
  for (var s = 0; s < chans.first.raw.length; s++) {
    for (final c in chans) {
      raw.add((ByteData(2)..setInt16(0, c.raw[s], Endian.little)).buffer.asUint8List());
    }
  }

  final metaB = meta.toBytes();
  final rawB = raw.toBytes();
  final out = BytesBuilder()..add(Uint8List.fromList([0x54, 0x44, 0x53, 0x6D]));
  u32(out, (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7)); // meta|newlist|raw|interleaved|daqmx
  u32(out, 4713);
  u64(out, metaB.length + rawB.length);
  u64(out, metaB.length);
  out
    ..add(metaB)
    ..add(rawB);
  return out.toBytes();
}

void main() {
  test('decodes DAQmx format-changing scaler data and applies the linear scale', () {
    final f = TdmsReader.read(_buildDaqmx());
    final g = f.group('g')!;
    // a: int16 [10,20,30] * 0.5 + 1  ->  [6, 11, 16]
    expect(g.channel('a')!.data, [6.0, 11.0, 16.0]);
    // b: int16, no scaling
    expect(g.channel('b')!.data, [-1.0, -2.0, -3.0]);
  });
}
