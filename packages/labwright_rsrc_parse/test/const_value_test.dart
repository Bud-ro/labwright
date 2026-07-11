import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';
import 'test_util.dart';

/// Object/group open record: `10 <tag> 02 fe <u16 kind> fd <u16 oid>`.
List<int> open(int kind, int oid) => [0x10, 0x19, 0x02, 0xfe, kind >> 8, kind & 0xff, 0xfd, oid >> 8, oid & 0xff];
List<int> close() => [0x08, 0x19];

/// `0x26C` constValue records at each stored width (`x6` ops carry tag bit 9).
List<int> cvU8(int v) => [0x26, 0x6c, v];
List<int> cvU16(int v) => [0x46, 0x6c, v >> 8, v & 0xff];
List<int> cvU32(int v) => [0x86, 0x6c, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> cvRaw(List<int> payload) => [0xc6, 0x6c, payload.length, ...payload];

/// Enum/ring item table `C4 2E <len> <pascal items>`.
List<int> items2e(List<String> items) {
  final b = [for (final it in items) ...pascal(it)];
  return [0xc4, 0x2e, b.length, ...b];
}

/// A `0x13` constant DCO wrapping one [inner]-class child, with [rec] scoped to
/// the DCO (after the child closes) — the corpus layout of a BD constant.
List<int> constant(int oid, int inner, List<int> rec, {List<int> innerBody = const []}) => [
  ...open(0x13, oid),
  ...open(inner, oid + 1),
  ...innerBody,
  ...close(),
  ...rec,
  ...close(),
];

ViDiagram dia(List<int> records) => buildDiagram(u8([0, 0, 0, records.length, ...records]));

void main() {
  test('decodeBdConstantValue gates: booleans, integers, doubles, zeros', () {
    final rows = <(List<int>, Object?)>[
      // Booleans: 0x4f carrier, {0,1} at <=2 bytes.
      (constant(1, 0x4f, cvU8(1)), true),
      (constant(1, 0x4f, cvU16(0)), false),
      (constant(1, 0x4f, cvU8(2)), null), // out of domain
      // Integers: 0x50 carrier, non-negative in every reading.
      (constant(1, 0x50, cvU32(256)), 256),
      (constant(1, 0x50, cvU8(0)), 0),
      (constant(1, 0x50, cvU32(100000000)), 100000000), // SGL reading is denormal
      (constant(1, 0x50, cvU32(0xffffffff)), null), // i32 -1 vs u32 max
      (constant(1, 0x50, cvU8(0xff)), null), // i8 -1 vs 255
      (constant(1, 0x50, cvU32(0x3f800000)), null), // plausible SGL 1.0 bits
      // Doubles: 8-byte payload, sane f64 only.
      (constant(1, 0x50, cvRaw([0x40, 0, 0, 0, 0, 0, 0, 0])), 2.0),
      (constant(1, 0x50, cvRaw([0xc0, 0x5e, 0xdc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcd])), -123.45),
      (constant(1, 0x50, cvRaw(List.filled(8, 0xff))), null), // NaN = i64 -1
      (constant(1, 0x50, cvRaw([0, 0, 0, 0, 0, 0, 0, 5])), null), // denormal = small i64
      // Containered zero of a wider type.
      (constant(1, 0x50, cvRaw(List.filled(5, 0))), 0),
      (constant(1, 0x50, cvRaw(List.filled(9, 0))), 0),
      // Enums/rings decode their stored integer only with an item table.
      (constant(1, 0x57, cvU16(3), innerBody: items2e(['a', 'b', 'c', 'd'])), 3),
      (constant(1, 0x57, cvU16(3)), null),
      (constant(1, 0x64, cvU8(1), innerBody: items2e(['off', 'on'])), 1),
      // Unhandled carriers decline.
      (constant(1, 0x52, cvRaw([0, 0, 0, 0, 0, 0, 0, 1])), null), // array shell
      (constant(1, 0x51, cvU32(1)), null), // string carrier is constText's
    ];
    for (final (records, want) in rows) {
      final o = dia(records).byId[1]!;
      expect(o.constBool ?? o.constNumeric, want, reason: records.map((b) => b.toRadixString(16)).join(' '));
    }
  });

  test('corpus pins: known constant values', () {
    if (!corpusViDir.existsSync()) return;
    // crc8.png (VI snippet): CRC width 8, table size 256, bit-reversal LUT.
    final crc8 = File('${corpusViDir.path}/rcpacini_VI-Snippets/rcpacini-VI-Snippets-1662bd7/crc8.png');
    final vi = extractSnippetVi(crc8.readAsBytesSync())!;
    final bd = buildViModel(vi).blockDiagrams.single;
    final pins = <int, Object?>{
      134: 8, // "8-bits" shift count
      3031: 256, // table size
      387: 256, // byte count
      197: false, // carry seed
      750: null, // the 256-entry LUT array payload is framed, not value-decoded
    };
    pins.forEach((oid, want) {
      final o = bd.byId[oid]!;
      expect(o.constBool ?? o.constNumeric, want, reason: 'crc8 oid $oid');
    });

    // A DFDS-bearing LV17 VI: doubles, u32s, strings, and declined ambiguity.
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
      expect(bd5.byId[2924]!.constNumeric, isNull, reason: '0xFFFFFFFF is i32 -1 or u32 max: declined');

      // The same VI's tiled data space carries the constants' values: the
      // ground-truth mechanism behind the decode census (see
      // decodeBdConstantValue). "Test Status" sits in a 15-byte string slot.
      final decoded = decodeSections(bytes);
      Uint8List? vctp, tm80, dfds;
      for (final d in decoded) {
        if (d.tag == 'VCTP') vctp ??= d.bytes;
        if (d.tag == 'TM80') tm80 ??= d.bytes;
        if (d.tag == 'DFDS') dfds ??= d.bytes;
      }
      final slots = dataSpaceSlots(dfds!, DfdsContext(vctp: vctp!, tm80: tm80!, verGe10: true))!;
      expect(slots, hasLength(37));
      final slot = slots.singleWhere((s) => s.offset == 1947);
      expect((slot.topLevelIndex, slot.length), (324, 15));
      expect(
        String.fromCharCodes(Uint8List.sublistView(dfds, slot.offset + 4, slot.offset + slot.length)),
        'Test Status',
      );
    }
  });
}
