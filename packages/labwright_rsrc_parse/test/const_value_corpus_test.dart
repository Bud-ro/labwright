@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'shape_probe.dart';

void main() {
  test('corpus pins: known constant values', () {
    final crc8 = File('${corpusViDir.path}/vi-corpus/sources/rcpacini__VI-Snippets/crc8.png');
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
      final o = bd.byOid(oid)!;
      expect(o.constant?.boolValue ?? o.constant?.numeric, want, reason: 'crc8 oid $oid');
    });
    expect(bd.byOid(757)!.arrayIndex, 255, reason: 'LUT shell index');
    expect(bd.byOid(2369)!.arrayIndex, 255, reason: 'zero-LUT shell index');
    expect(bd.byOid(750)!.constant?.array![255], 255, reason: 'LUT[255]');

    final md5 = File('${corpusViDir.path}/vi-corpus/sources/rcpacini__VI-Snippets/MD5.png');
    final bdM = buildViModel(extractSnippetVi(md5.readAsBytesSync())!).blockDiagrams.single;
    expect(bdM.byOid(821)!.constant?.numeric, 0x67452301, reason: 's1 in');
    expect(bdM.byOid(796)!.constant?.numeric, 0xEFCDAB89, reason: 's2 in: leading byte >= 0x80, typed u32');
    expect(bdM.byOid(757)!.constant?.numeric, 0x10325476, reason: 's4 in: above the SGL-alias ceiling, typed u32');
    expect(bdM.byOid(4928)!.constant?.arrayDims, [4, 16], reason: 'Indices 2D');
    expect(bdM.byOid(4928)!.constant?.array!.take(4), [0, 1, 2, 3]);
    expect(bdM.byOid(4969)!.constant?.arrayDims, [64], reason: 'T 1D');
    expect(bdM.byOid(4969)!.constant?.array!.first, 0xD76AA478);
    expect(bdM.byOid(943)!.constant?.arrayDims, [0], reason: 'empty array: dims + 1 zero pad byte');
    expect(bdM.byOid(943)!.constant?.array, isEmpty);
    expect(bdM.byOid(814)!.displayFormat, '%08x', reason: 's1 value window');
    expect(bdM.byOid(4996)!.displayFormat, '%x', reason: 'T element window');

    final test5 = File(
      '${corpusViDir.path}/vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/'
      'testcases/testcase-CSMGlobalLog/test5-Broadcast_Queue.vi',
    );
    expect(test5.existsSync(), isTrue, reason: 'the pinned VI must be fetched with the corpus');
    final bytes = test5.readAsBytesSync();
    final bd5 = buildViModel(bytes).blockDiagrams.single;
    expect(bd5.byOid(1148)!.constant?.numeric, 10, reason: 'milliseconds to wait');
    expect(bd5.byOid(2592)!.constant?.boolValue, true);
    expect(bd5.byOid(2692)!.constant?.text, 'Test Status');
    expect(bd5.byOid(2924)!.resolvedType?.kind, ViDataType.i32);
    expect(bd5.byOid(2924)!.constant?.numeric, -1);

    final sections = readViSections(bytes);
    final dfdsSection = sections.firstWhere((s) => s.tag == 'DFDS');
    final dfds = inflateHeapPayload(dfdsSection.bytes)!;
    final slots = ViDataSpace(dfds, dataSpaceContexts(sections)[dfdsSection.index]!).slots;
    expect(slots, hasLength(37));
    final strSlot = slots.singleWhere((DataSpaceSlot s) => s.offset == 1947);
    expect((strSlot.topLevelIndex, strSlot.length), (324, 15));
    expect(
      String.fromCharCodes(Uint8List.sublistView(dfds, strSlot.offset + 4, strSlot.offset + strSlot.length)),
      'Test Status',
    );
    final numSlot = slots.singleWhere((DataSpaceSlot s) => s.offset == 2104);
    expect(numSlot.length, 4);
    expect(
      ByteData.sublistView(dfds, numSlot.offset, numSlot.offset + 4).getUint32(0),
      bd5.byOid(1148)!.constant?.numeric,
      reason: 'decoded constant value byte-matches its data-space slot',
    );
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
    final diagrams = <String, BdDiagram>{};
    for (final (snippet, oid, value, width, height) in pins) {
      final diagram = diagrams[snippet] ??= buildViModel(
        extractSnippetVi(snippetPng('$snippet.png').readAsBytesSync())!,
      ).blockDiagrams.single;
      final constant = diagram.byOid(oid)!;
      expect(constant.constant?.text, value, reason: '$snippet oid $oid value');
      final box = diagram.children(oid).firstWhere((child) => child.absBounds != null).absBounds!;
      expect((box.width, box.height), (width, height), reason: '$snippet oid $oid box');
      expect(bdDrawnConstText(constant), value.codeUnits.every((c) => c >= 0x20 && c < 0x7f) ? value : isNull);
    }
  });

  test('corpus pins: string array constants', () {
    const csm =
        'vi-corpus/sources/NEVSTOP-LAB__Communicable-State-Machine/src/user.lib/_NEVSTOP/'
        'Communicable State Machine(CSM)';
    final pins = <(String, int, List<int>, List<String>)>[
      ('$csm/_Shared/Remove Comments from Single-line.vi', 43, [2], ['//', '/*']),
      ('$csm/_csmDoc/Support/_list_CSM documented VIs.vi', 299, [3], ['*.vi', '*.vim', '*.vit']),
      (
        'vi-corpus/sources/JKISoftware__JKI-State-Machine-Objects/src/Support/Attribute.Dependencies/Remove Dependency.vi',
        488,
        [0],
        [],
      ),
    ];
    for (final (path, oid, dims, texts) in pins) {
      final diagram = buildViModel(File('${corpusViDir.path}/$path').readAsBytesSync()).blockDiagrams.single;
      final constant = diagram.byOid(oid)!;
      expect(constant.constant?.arrayDims, dims, reason: '$path oid $oid dims');
      expect(constant.constant?.textArray, texts, reason: '$path oid $oid elements');
      expect(constant.constant?.array, isNull, reason: '$path oid $oid numbers');
    }
  });
}
