// Hand-built segment bytes exercise reader paths the TdmsWriter never emits:
// big-endian, interleaved raw data, raw integer/double types, and DAQmx
// format-changing scalers.
import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:test/test.dart';

import 'util.dart';

const _tocMeta = 1 << 1, _tocNewObj = 1 << 2, _tocRaw = 1 << 3;
const _tocInterleaved = 1 << 5, _tocBigEndian = 1 << 6, _tocDaqmx = 1 << 7;

class _B {
  _B([this.e = Endian.little]);
  final Endian e;
  final _out = BytesBuilder();
  void u32(int v) => _n(4, (d) => d.setUint32(0, v, e));
  void u64(int v) => _n(8, (d) => d.setUint64(0, v, e));
  void f64(double v) => _n(8, (d) => d.setFloat64(0, v, e));
  void i16(int v) => _n(2, (d) => d.setInt16(0, v, e));

  void str(String s) {
    final u = utf8.encode(s);
    u32(u.length);
    _out.add(u);
  }

  /// One raw element of on-disk type code [dtype] (3=I32, 6=U16, 10=Double).
  void elem(int dtype, num v) {
    switch (dtype) {
      case 3:
        _n(4, (d) => d.setInt32(0, v.toInt(), e));
      case 6:
        _n(2, (d) => d.setUint16(0, v.toInt(), e));
      case 10:
        f64(v.toDouble());
      default:
        throw ArgumentError('dtype $dtype');
    }
  }

  void _n(int width, void Function(ByteData) put) {
    final d = ByteData(8);
    put(d);
    _out.add(d.buffer.asUint8List(0, width));
  }

  Uint8List take() => _out.toBytes();
}

/// One-segment file: TDSm tag, always-little ToC, then lead-in tail/meta/raw in [e].
Uint8List _file(Endian e, int toc, _B meta, _B raw) {
  final m = meta.take(), r = raw.take();
  final tail = _B(e)
    ..u32(4713)
    ..u64(m.length + r.length)
    ..u64(m.length);
  return (BytesBuilder()
        ..add('TDSm'.codeUnits)
        ..add((_B()..u32(toc)).take())
        ..add(tail.take())
        ..add(m)
        ..add(r))
      .toBytes();
}

typedef _Chan = ({String path, int dtype, List<num> values});

Uint8List _plain(Endian e, {required bool interleaved, required List<_Chan> chans}) {
  final meta = _B(e)..u32(chans.length);
  for (final c in chans) {
    meta
      ..str(c.path)
      ..u32(20) // raw index length
      ..u32(c.dtype)
      ..u32(1) // dimension
      ..u64(c.values.length)
      ..u32(0); // property count
  }
  final raw = _B(e);
  if (interleaved) {
    for (var s = 0; s < chans.first.values.length; s++) {
      for (final c in chans) {
        raw.elem(c.dtype, c.values[s]);
      }
    }
  } else {
    for (final c in chans) {
      for (final v in c.values) {
        raw.elem(c.dtype, v);
      }
    }
  }
  var toc = _tocMeta | _tocNewObj | _tocRaw;
  if (e == Endian.big) toc |= _tocBigEndian;
  if (interleaved) toc |= _tocInterleaved;
  return _file(e, toc, meta, raw);
}

void main() {
  const le = Endian.little, be = Endian.big;
  // dart format off
  final cases = <(String, Endian, bool, List<_Chan>, Map<String, List<double>>)>[
    ('little-endian i32', le, false,
        [(path: "/'g'/'i'", dtype: 3, values: [-5, 0, 7, 2147483647])], {'g/i': [-5, 0, 7, 2147483647]}),
    ('big-endian i32', be, false,
        [(path: "/'g'/'i'", dtype: 3, values: [-5, 0, 7, -2147483648])], {'g/i': [-5, 0, 7, -2147483648]}),
    ('little-endian u16', le, false,
        [(path: "/'g'/'u'", dtype: 6, values: [0, 1, 65535, 1000])], {'g/u': [0, 1, 65535, 1000]}),
    ('big-endian u16', be, false,
        [(path: "/'g'/'u'", dtype: 6, values: [0, 1, 65535, 1000])], {'g/u': [0, 1, 65535, 1000]}),
    ('little-endian f64', le, false,
        [(path: "/'g'/'d'", dtype: 10, values: [1.5, -2.25, 0])], {'g/d': [1.5, -2.25, 0]}),
    ('big-endian f64', be, false,
        [(path: "/'g'/'d'", dtype: 10, values: [1.5, -2.25, 0])], {'g/d': [1.5, -2.25, 0]}),
    ('interleaved i32 pair (sample-major)', le, true,
        [(path: "/'g'/'a'", dtype: 3, values: [1, 2, 3]), (path: "/'g'/'b'", dtype: 3, values: [10, 20, 30])],
        {'g/a': [1, 2, 3], 'g/b': [10, 20, 30]}),
    ('big-endian interleaved u16 pair', be, true,
        [(path: "/'g'/'a'", dtype: 6, values: [1, 2, 3]), (path: "/'g'/'b'", dtype: 6, values: [10, 20, 30])],
        {'g/a': [1, 2, 3], 'g/b': [10, 20, 30]}),
    ('interleaved mixed-width i32 + u16', le, true,
        [(path: "/'g'/'a'", dtype: 3, values: [-1, 2]), (path: "/'g'/'b'", dtype: 6, values: [7, 8])],
        {'g/a': [-1, 2], 'g/b': [7, 8]}),
  ];
  // dart format on
  for (final (name, e, interleaved, chans, want) in cases) {
    test(name, () {
      expect(channelsOf(TdmsReader.read(_plain(e, interleaved: interleaved, chans: chans))), want);
    });
  }

  test('DAQmx format-changing scaler: interleaved i16, linear scale on one channel', () {
    const stride = 4;
    final chans = [
      (path: "/'g'/'a'", offset: 0, raw: [10, 20, 30], scale: true),
      (path: "/'g'/'b'", offset: 2, raw: [-1, -2, -3], scale: false),
    ];
    final meta = _B()..u32(chans.length);
    for (final c in chans) {
      meta
        ..str(c.path)
        ..u32(0x1269) // DAQmx format-changing raw index
        ..u32(0xFFFFFFFF)
        ..u32(1)
        ..u64(c.raw.length)
        // one raw buffer index: i16 at byte offset [c.offset] within a [stride]-byte scan
        ..u32(1)
        ..u32(3)
        ..u32(0)
        ..u32(c.offset)
        ..u32(0)
        ..u32(0)
        ..u32(1)
        ..u32(stride);
      if (!c.scale) {
        meta.u32(0);
        continue;
      }
      meta.u32(3);
      for (final (name, value) in const <(String, Object)>[
        ('NI_Scaling_Status', 'unscaled'),
        ('NI_Scale[1]_Linear_Slope', 0.5),
        ('NI_Scale[1]_Linear_Y_Intercept', 1.0),
      ]) {
        meta.str(name);
        if (value is String) {
          meta
            ..u32(0x20)
            ..str(value);
        } else {
          meta
            ..u32(10)
            ..f64(value as double);
        }
      }
    }
    final raw = _B();
    for (var s = 0; s < 3; s++) {
      for (final c in chans) {
        raw.i16(c.raw[s]);
      }
    }
    const toc = _tocMeta | _tocNewObj | _tocRaw | _tocInterleaved | _tocDaqmx;
    final f = TdmsReader.read(_file(Endian.little, toc, meta, raw));
    // dart format off
    expect(channelsOf(f), {
      'g/a': [6.0, 11.0, 16.0], // int16 [10,20,30] * 0.5 + 1
      'g/b': [-1.0, -2.0, -3.0], // unscaled
    });
    // dart format on
  });
}
