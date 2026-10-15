/// `HIST` - Revision History: [ViHistory]
///
/// The VI's revision number and history settings in a fixed 40-byte record; every corpus file
/// has one. Words 4 to 6 and 9 are zero except in 175 files, where they hold a rectangle about
/// 390 by 280 pixels and two small counts, the natural reading being the History window's bounds.
///
/// ```text
/// offset  size  field          type   meaning
/// 0       4     formatVersion  u32    Always 2.
/// 4       4     flags          u32    History settings: bit 10 is set in all but 5 files, bit 8 in 34, bits
///                                     2 and 5 once each; roles TODO.
/// 8       4     revisionNumber u32    The revision number the History window shows, 1 to 2597 in the corpus.
/// 12      4     reserved12     u32    Zero.
/// 16      4     unknown16             Zero, or 3, 4 or 5 when the rectangle is set; role TODO.
/// 20      2     top            i16    The rectangle words 5 and 6 hold, as top, left, bottom and right; all
///                                     zero in all but 175 files.
/// 22      2     left           i16    The rectangle words 5 and 6 hold, as top, left, bottom and right; all
///                                     zero in all but 175 files.
/// 24      2     bottom         i16    The rectangle words 5 and 6 hold, as top, left, bottom and right; all
///                                     zero in all but 175 files.
/// 26      2     right          i16    The rectangle words 5 and 6 hold, as top, left, bottom and right; all
///                                     zero in all but 175 files.
/// 28      8     reserved28     u32[2] Zero.
/// 36      4     unknown36             Zero, or 2 to 14 when the rectangle is set; role TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViHistory extends ByteRecord {
  ViHistory(Uint8List bytes) : super(bytes, layout);

  /// Always 2.
  int get formatVersion => _formatVersion.read(view);

  /// History settings: bit 10 is set in all but 5 files, bit 8 in 34, bits 2 and 5 once each;
  /// roles TODO.
  int get flags => _flags.read(view);

  /// The revision number the History window shows, 1 to 2597 in the corpus.
  int get revisionNumber => _revisionNumber.read(view);

  /// Whether the reserved words are zero.
  bool get reservedAreZero =>
      _reserved12.read(view) == 0 && _reserved28.at(view, 0) == 0 && _reserved28.at(view, 1) == 0;

  /// The rectangle words 5 and 6 hold, as top, left, bottom and right; all zero in all but 175
  /// files.
  (int, int, int, int) get windowBounds => (_top.read(view), _left.read(view), _bottom.read(view), _right.read(view));

  /// Zero.
  int get reserved12 => _reserved12.read(view);

  /// Zero, or 3, 4 or 5 when the rectangle is set; role TODO.
  Uint8List get unknown16 => _unknown16.read(view);

  /// Zero.
  List<int> get reserved28 => _reserved28.read(view);

  /// Zero, or 2 to 14 when the rectangle is set; role TODO.
  Uint8List get unknown36 => _unknown36.read(view);

  static Uint8List encode({
    int formatVersion = 2,
    required int flags,
    required int revisionNumber,
    int reserved12 = 0,
    required List<int> unknown16,
    int top = 0,
    int left = 0,
    int bottom = 0,
    int right = 0,
    List<int> reserved28 = const [0, 0],
    required List<int> unknown36,
  }) {
    final out = Uint8List(layout.size!);
    final view = ByteData.sublistView(out);
    _formatVersion.write(view, formatVersion);
    _flags.write(view, flags);
    _revisionNumber.write(view, revisionNumber);
    _reserved12.write(view, reserved12);
    _unknown16.write(view, unknown16);
    _top.write(view, top);
    _left.write(view, left);
    _bottom.write(view, bottom);
    _right.write(view, right);
    _reserved28.write(view, reserved28);
    _unknown36.write(view, unknown36);
    return out;
  }

  // dart format off
  static const _formatVersion = U32(0);
  static const _flags = U32(4);
  static const _revisionNumber = U32(8);
  static const _reserved12 = U32(12); // Zero.
  static const _unknown16 = Unknown(16, size: 4); // Zero, or 3, 4 or 5 when the rectangle is set; role TODO.
  static const _top = I16(20);
  static const _left = I16(22);
  static const _bottom = I16(24);
  static const _right = I16(26);
  static const _reserved28 = U32List(28, length: 2); // Zero.
  static const _unknown36 = Unknown(36, size: 4); // Zero, or 2 to 14 when the rectangle is set; role TODO.

  static const layout = ByteLayout([_formatVersion, _flags, _revisionNumber, _reserved12, _unknown16, _top, _left, _bottom, _right, _reserved28, _unknown36]);
  // dart format on
}
