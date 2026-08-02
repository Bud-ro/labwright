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
List<int> cvU24(int v) => [0x66, 0x6c, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> cvU32(int v) => [0x86, 0x6c, (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> cvRaw(List<int> payload) => [0xc6, 0x6c, payload.length, ...payload];
List<int> f64(double v) => (ByteData(8)..setFloat64(0, v)).buffer.asUint8List();

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

/// Build + decode with no VCTP types in play: exercises the fallback tier of
/// [decodeBdConstValues] alone.
ViDiagram dia(List<int> records) {
  final d = buildDiagram(u8([0, 0, 0, records.length, ...records]));
  decodeBdConstValues(d);
  return d;
}

void main() {
  test('decodeBdConstantValue gates: accept and decline sides of each', () {
    final rows = <(List<int>, Object?)>[
      // Booleans: 0x4f carrier, {0,1} at <= 2 bytes.
      (constant(1, 0x4f, cvU8(1)), true),
      (constant(1, 0x4f, cvU16(0)), false),
      (constant(1, 0x4f, cvU8(2)), null), // out of domain
      (constant(1, 0x4f, cvU24(1)), null), // width > 2 declines
      (constant(1, 0x4f, cvU32(1)), null), // width > 2 declines
      // Integers: 0x50 carrier, non-negative in every reading, below 2^23.
      (constant(1, 0x50, cvU32(256)), 256),
      (constant(1, 0x50, cvU8(0)), 0),
      (constant(1, 0x50, cvU32(0x7fffff)), 0x7fffff), // last certain value
      (constant(1, 0x50, cvU32(0x800000)), null), // reads as a normal SGL too
      (constant(1, 0x50, cvU32(100000000)), null), // ditto
      (constant(1, 0x50, cvU32(0xffffffff)), null), // i32 -1 vs u32 max
      (constant(1, 0x50, cvU8(0xff)), null), // i8 -1 vs 255
      (constant(1, 0x50, cvU32(0x3f800000)), null), // SGL 1.0 bits
      // Doubles: 8-byte payload, finite f64 within the magnitude window.
      (constant(1, 0x50, cvRaw(f64(2.0))), 2.0),
      (constant(1, 0x50, cvRaw(f64(-123.45))), -123.45),
      (constant(1, 0x50, cvRaw(f64(1e-9))), 1e-9),
      (constant(1, 0x50, cvRaw(f64(1e13))), null), // above the window ceiling
      (constant(1, 0x50, cvRaw(f64(1e-13))), null), // below the window floor
      (constant(1, 0x50, cvRaw(f64(double.infinity))), null), // plausible i64 bits
      (constant(1, 0x50, cvRaw(f64(double.negativeInfinity))), null),
      (constant(1, 0x50, cvRaw(List.filled(8, 0xff))), null), // NaN = i64 -1
      (constant(1, 0x50, cvRaw([0, 0, 0, 0, 0, 0, 0, 5])), null), // denormal = small i64
      (constant(1, 0x50, cvRaw(List.filled(8, 0))), 0.0), // +0.0
      // Containered zero of a 4/8-byte type — and only those widths.
      (constant(1, 0x50, cvRaw(List.filled(5, 0))), 0),
      (constant(1, 0x50, cvRaw(List.filled(9, 0))), 0),
      (constant(1, 0x50, cvRaw(List.filled(4, 0))), null),
      (constant(1, 0x50, cvRaw(List.filled(17, 0))), null), // extended-width zero
      (constant(1, 0x50, cvRaw(const [])), null),
      // Enums/rings decode their stored integer only with an item table.
      (constant(1, 0x57, cvU16(3), innerBody: items2e(['a', 'b', 'c', 'd'])), 3),
      (constant(1, 0x57, cvU16(3)), null),
      (constant(1, 0x64, cvU8(1), innerBody: items2e(['off', 'on'])), 1),
      (constant(1, 0x64, cvU8(1)), null),
      // Unhandled carriers decline.
      (constant(1, 0x52, cvRaw(f64(2.0))), null), // array shell
      (constant(1, 0x51, cvU32(1)), null), // string carrier is constText's
    ];
    for (final (records, want) in rows) {
      final o = dia(records).byId[1]!;
      // Exactly one field carries the decode; the others stay null.
      expect(
        (o.constBool, o.constNumeric, o.constText),
        (want is bool ? want : null, want is num ? want : null, null),
        reason: records.map((b) => b.toRadixString(16)).join(' '),
      );
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

    // MD5.png: the typed tier of decodeBdConstValues settles the fallback
    // gates' SGL-alias/sign declines and decodes array payloads;
    // display-format text rides the 0xe0 window.
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

    // A DFDS-bearing LV17 VI: ints, bools, strings, and declined ambiguity.
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

      // The same VI's tiled data space carries the constants' values — the
      // ground-truth mechanism behind the decode census (see
      // decodeBdConstantValue): "Test Status" sits in a 15-byte string slot,
      // and the decoded 10 byte-matches its 4-byte slot.
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
