@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  test('corpus pins: known constant values', () {
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
}
