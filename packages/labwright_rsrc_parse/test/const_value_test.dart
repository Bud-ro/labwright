import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../tool/corpus_base.dart';
import 'test_util.dart';

List<int> cvU8(int v) => [0x26, 0x6c, v];
List<int> cvU16(int v) => [0x46, 0x6c, v >> 8, v & 0xff];
List<int> cvU24(int v) => [0x66, 0x6c, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> cvU32(int v) => [0x86, 0x6c, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> cvRaw(List<int> payload) => [0xc6, 0x6c, payload.length, ...payload];
List<int> f64(double v) => (ByteData(8)..setFloat64(0, v)).buffer.asUint8List();

List<int> constant(int oid, int inner, List<int> rec, {List<int> innerBody = const []}) => [
  ...open(0x13, oid),
  ...open(inner, oid + 1),
  ...innerBody,
  ...close(),
  ...rec,
  ...close(),
];

ViDiagram dia(List<int> records) {
  final d = buildDiagram(heapBody(records));
  decodeBdConstValues(d);
  return d;
}

void main() {
  test('decodeBdConstantValue gates: accept and decline sides of each', () {
    final rows = <(List<int>, Object?)>[
      (constant(1, 0x4f, cvU8(1)), true),
      (constant(1, 0x4f, cvU16(0)), false),
      (constant(1, 0x4f, cvU8(2)), null),
      (constant(1, 0x4f, cvU24(1)), null),
      (constant(1, 0x4f, cvU32(1)), null),
      (constant(1, 0x50, cvU32(256)), 256),
      (constant(1, 0x50, cvU8(0)), 0),
      (constant(1, 0x50, cvU32(0x7fffff)), 0x7fffff),
      (constant(1, 0x50, cvU32(0x800000)), null),
      (constant(1, 0x50, cvU32(100000000)), null),
      (constant(1, 0x50, cvU32(0xffffffff)), null),
      (constant(1, 0x50, cvU8(0xff)), null),
      (constant(1, 0x50, cvU32(0x3f800000)), null),
      (constant(1, 0x50, cvRaw(f64(2.0))), 2.0),
      (constant(1, 0x50, cvRaw(f64(-123.45))), -123.45),
      (constant(1, 0x50, cvRaw(f64(1e-9))), 1e-9),
      (constant(1, 0x50, cvRaw(f64(1e13))), null),
      (constant(1, 0x50, cvRaw(f64(1e-13))), null),
      (constant(1, 0x50, cvRaw(f64(double.infinity))), null),
      (constant(1, 0x50, cvRaw(f64(double.negativeInfinity))), null),
      (constant(1, 0x50, cvRaw(List.filled(8, 0xff))), null),
      (constant(1, 0x50, cvRaw([0, 0, 0, 0, 0, 0, 0, 5])), null),
      (constant(1, 0x50, cvRaw(List.filled(8, 0))), 0.0),
      (constant(1, 0x50, cvRaw(List.filled(5, 0))), 0),
      (constant(1, 0x50, cvRaw(List.filled(9, 0))), 0),
      (constant(1, 0x50, cvRaw(List.filled(4, 0))), null),
      (constant(1, 0x50, cvRaw(List.filled(17, 0))), null),
      (constant(1, 0x50, cvRaw(const [])), null),
      (constant(1, 0x57, cvU16(3), innerBody: enum2e(['a', 'b', 'c', 'd'])), 3),
      (constant(1, 0x57, cvU16(3)), null),
      (constant(1, 0x64, cvU8(1), innerBody: enum2e(['off', 'on'])), 1),
      (constant(1, 0x64, cvU8(1)), null),
      (constant(1, 0x52, cvRaw(f64(2.0))), null),
      (constant(1, 0x51, cvU32(1)), null),
    ];
    for (final (records, want) in rows) {
      final o = dia(records).byId[1]!;
      expect(
        (o.constBool, o.constNumeric, o.constText),
        (want is bool ? want : null, want is num ? want : null, null),
        reason: records.map((b) => b.toRadixString(16)).join(' '),
      );
    }
  });

  test('string framing: the reference renders that settle a non-printable payload', () {
    const pins = <(String, int, String, int, int)>[
      ('Config_Escape', 307, r'\t', 24, 19),
      ('Config_Escape', 2004, '\t', 24, 19),
      ('Config_Escape', 347, r'\n', 27, 19),
      ('Config_Escape', 1812, '\n', 27, 19),
      ('Config_Escape', 379, r'\f', 24, 19),
      ('Config_Escape', 1908, '\f', 24, 19),
      ('Config_Escape', 411, r'\r', 24, 19),
      ('Config_Escape', 1956, '\r', 24, 19),
      ('Config_Escape', 475, r'\\', 25, 19),
      ('Config_Escape', 1764, r'\', 25, 19),
      ('Config_Escape', 443, r'\"', 25, 19),
      ('Config_Escape', 1860, '"', 20, 19),
      ('Config_Dump', 671, '\n', 27, 19),
      ('Config_Dump', 712, '\n', 27, 19),
      ('Config_Dump', 2448, '\n', 27, 19),
      ('Config_Dump', 1575, '=', 17, 19),
    ];
    final diagrams = <String, ViDiagram>{};
    for (final (snippet, oid, value, width, height) in pins) {
      final diagram = diagrams[snippet] ??= buildViModel(
        extractSnippetVi(File('${corpusBaseDir().path}/snippets/$snippet.png').readAsBytesSync())!,
      ).blockDiagrams.single;
      final constant = diagram.byId[oid]!;
      expect(constant.constText, value, reason: '$snippet oid $oid value');
      final box = diagram.children(oid).firstWhere((child) => child.absBounds != null).absBounds!;
      expect((box.width, box.height), (width, height), reason: '$snippet oid $oid box');
      expect(bdDrawnConstText(constant), value.codeUnits.every((c) => c >= 0x20 && c < 0x7f) ? value : isNull);
    }
  });
}
