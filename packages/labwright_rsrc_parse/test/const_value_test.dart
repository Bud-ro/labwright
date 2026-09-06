import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../tool/corpus_base.dart';
import 'corpus_dirs.dart';
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

  test('corpus pins: known constant values', () {
    if (!corpusOrSkip(corpusViDir)) return;
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    final vi = extractSnippetVi(crc8.readAsBytesSync())!;
    final bd = buildViModel(vi).blockDiagrams.single;
    final pins = <int, Object?>{
      134: 8,
      3031: 256,
      387: 256,
      197: false,
      750: null,
    };
    pins.forEach((oid, want) {
      final o = bd.byId[oid]!;
      expect(o.constBool ?? o.constNumeric, want, reason: 'crc8 oid $oid');
    });
    expect(bd.byId[757]!.arrayIndex, 255, reason: 'LUT shell index');
    expect(bd.byId[2369]!.arrayIndex, 255, reason: 'zero-LUT shell index');
    expect(bd.byId[750]!.constArray![255], 255, reason: 'LUT[255]');

    final md5 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/MD5.png');
    final bdM = buildViModel(extractSnippetVi(md5.readAsBytesSync())!).blockDiagrams.single;
    expect(bdM.byId[821]!.constNumeric, 0x67452301, reason: 's1 in');
    expect(bdM.byId[796]!.constNumeric, 0xEFCDAB89, reason: 's2 in: leading byte >= 0x80, typed u32');
    expect(bdM.byId[757]!.constNumeric, 0x10325476, reason: 's4 in: above the SGL-alias ceiling, typed u32');
    expect(bdM.byId[4928]!.constArrayDims, [4, 16], reason: 'Indices 2D');
    expect(bdM.byId[4928]!.constArray!.take(4), [0, 1, 2, 3]);
    expect(bdM.byId[4969]!.constArrayDims, [64], reason: 'T 1D');
    expect(bdM.byId[4969]!.constArray!.first, 0xD76AA478);
    expect(bdM.byId[943]!.constArrayDims, [0], reason: 'empty array: dims + 1 zero pad byte');
    expect(bdM.byId[943]!.constArray, isEmpty);
    expect(bdM.byId[814]!.displayFormat, '%08x', reason: 's1 value window');
    expect(bdM.byId[4996]!.displayFormat, '%x', reason: 'T element window');

    final test5 = File(
      '${corpusViDir.path}/NEVSTOP-LAB_Communicable-State-Machine/'
      'NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/testcases/testcase-CSMGlobalLog/test5-Broadcast_Queue.vi',
    );
    if (test5.existsSync()) {
      final bytes = test5.readAsBytesSync();
      final bd5 = buildViModel(bytes).blockDiagrams.single;
      expect(bd5.byId[1148]!.constNumeric, 10, reason: 'milliseconds to wait');
      expect(bd5.byId[2592]!.constBool, true);
      expect(bd5.byId[2692]!.constText, 'Test Status');
      expect(bd5.byId[2924]!.resolvedType?.kind, ViDataType.i32);
      expect(bd5.byId[2924]!.constNumeric, -1);

      final decoded = decodeSections(bytes);
      Uint8List? vctp, tm80, dfds;
      for (final d in decoded) {
        if (d.tag == 'VCTP') vctp ??= d.bytes;
        if (d.tag == 'TM80') tm80 ??= d.bytes;
        if (d.tag == 'DFDS') dfds ??= d.bytes;
      }
      final slots = dataSpaceSlots(dfds!, DfdsContext(vctp: vctp!, tm80: tm80!, verGe10: true))!;
      expect(slots, hasLength(37));
      final strSlot = slots.singleWhere((s) => s.offset == 1947);
      expect((strSlot.topLevelIndex, strSlot.length), (324, 15));
      expect(
        String.fromCharCodes(Uint8List.sublistView(dfds, strSlot.offset + 4, strSlot.offset + strSlot.length)),
        'Test Status',
      );
      final numSlot = slots.singleWhere((s) => s.offset == 2104);
      expect(numSlot.length, 4);
      expect(
        ByteData.sublistView(dfds, numSlot.offset, numSlot.offset + 4).getUint32(0),
        bd5.byId[1148]!.constNumeric,
        reason: 'decoded constant value byte-matches its data-space slot',
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
