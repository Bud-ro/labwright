/// `TRec` - Text Record: [ViTextRecord]
///
/// One record per piece of text on the panel or diagram of a VI saved by LabVIEW 7.1 to 8.5,
/// stored as many `TRec` sections per file (2988 in the 35 corpus files, up to 114 in one) that
/// the heap refers to by section index: the text's bounds, a background colour and the text
/// itself, which is a control or pane label or a node name (`Pane`, `error out`, `status`,
/// `Merge Errors.vi`). 1335 sections carry no run. Later versions keep text in the heap instead.
///
/// ```text
/// offset  size      field           type          meaning
/// 0       4         unknown0                      0 in 1786 sections, else 0x200, 0x600, 0x8600 or 0x400;
///                                                 role TODO.
/// 4       4         unknown4                      A zero u16, then 0x4404, 0x0404, 0x0402 or a relative;
///                                                 roles TODO.
/// 8       4         zero8           u32           Zero.
/// 12      2         top             i16           The text's bounds as top, left, bottom, right; 15 pixels
///                                                 tall for one line.
/// 14      2         left            i16           The text's bounds as top, left, bottom, right; 15 pixels
///                                                 tall for one line.
/// 16      2         bottom          i16           The text's bounds as top, left, bottom, right; 15 pixels
///                                                 tall for one line.
/// 18      2         right           i16           The text's bounds as top, left, bottom, right; 15 pixels
///                                                 tall for one line.
/// 20      16        unknown20                     The bounds again as four i32, left one greater; role TODO.
/// 36      4         zero36          u32           Zero.
/// 40      4         backgroundColor u32           0x01000000 (transparent) in 1411 sections, white in 944,
///                                                 greys otherwise.
/// 44      28        unknown44                     Zero in 2496 sections, else small values at 48, 64, 68;
///                                                 TODO.
/// 72      rest      runs            TrecRun[]     Runs to the end of the payload.
///   +0    4         runLength       u32
///   +4    runLength text            u8[runLength]
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViTextRecord extends ByteRecord {
  ViTextRecord(Uint8List bytes) : super(bytes, layout) {
    final offsets = <int>[];
    var at = _runs.offset;
    while (at < view.lengthInBytes) {
      assert(at + 4 <= view.lengthInBytes, 'run ${offsets.length} has a length word');
      offsets.add(at);
      at += 4 + view.getUint32(at);
    }
    assert(at == view.lengthInBytes, 'the runs tile the payload');
    _runOffsets = offsets;
  }

  /// The text's bounds as top, left, bottom, right; 15 pixels tall for one line.
  (int, int, int, int) get bounds => (_top.read(view), _left.read(view), _bottom.read(view), _right.read(view));

  /// The 72 header bytes.
  Uint8List get header => Uint8List.sublistView(view, 0, _runs.offset);

  /// The background colour as LabVIEW encodes it, 0x01000000 meaning transparent.
  int get backgroundColor => _backgroundColor.read(view);

  /// One run, or none in 1335 of 2988 sections.
  int get runCount => _runOffsets.length;

  Uint8List runAt(int index) {
    final at = _runOffsets[index];
    return Uint8List.sublistView(
      view,
      at + TrecRun.text.offset,
      at + TrecRun.text.offset + view.getUint32(at + TrecRun.runLength.offset),
    );
  }

  late final List<int> _runOffsets;

  // dart format off
  static const _unknown0 = Unknown(0, size: 4); // 0 in 1786 sections, else 0x200, 0x600, 0x8600 or 0x400; role TODO.
  static const _unknown4 = Unknown(4, size: 4); // A zero u16, then 0x4404, 0x0404, 0x0402 or a relative; roles TODO.
  static const _zero8 = U32(8); // Zero.
  static const _top = I16(12);
  static const _left = I16(14);
  static const _bottom = I16(16);
  static const _right = I16(18);
  static const _unknown20 = Unknown(20, size: 16); // The bounds again as four i32, left one greater; role TODO.
  static const _zero36 = U32(36); // Zero.
  static const _backgroundColor = U32(40); // 0x01000000 (transparent) in 1411 sections, white in 944, greys otherwise.
  static const _unknown44 = Unknown(44, size: 28); // Zero in 2496 sections, else small values at 48, 64, 68; TODO.
  static const _runs = Entries(72, TrecRun.layout); // Runs to the end of the payload.

  static const layout = ByteLayout([_unknown0, _unknown4, _zero8, _top, _left, _bottom, _right, _unknown20, _zero36, _backgroundColor, _unknown44, _runs]);
  // dart format on
}

/// One text run.
abstract final class TrecRun {
  static const runLength = U32(0);
  static const text = Bytes(4, count: runLength);

  static const layout = ByteLayout([runLength, text]);
}
