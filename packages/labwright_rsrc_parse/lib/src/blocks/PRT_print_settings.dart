/// `PRT ` - Print Settings: [ViPrintRecord]
///
/// The page setup the VI was last printed or saved with, a little-endian record of 128 bytes
/// (one or two more words in 103 LabVIEW 2012 files): the printable area in printer pixels and
/// in points, the printer's pixels per point, and the four margins in inches, which with the
/// printable area add up to Letter in 2074 files and A4 in about 1100. The remaining words are
/// mostly zero; roles TODO.
///
/// ```text
/// offset  size  field                      type   meaning
/// 0       4     zero0                      u32le  Zero.
/// 4       4     one4                       u32le  Always 1.
/// 8       8     unknown8                          Two words, zero in all but 37 files; roles TODO.
/// 16      4     zero16                     u32le  Zero.
/// 20      2     printableHeightPixels      u16le  Printable height and width in printer pixels, 6392 by 4892
///                                                 for Letter at 600 dpi.
/// 22      2     printableWidthPixels       u16le  Printable height and width in printer pixels, 6392 by 4892
///                                                 for Letter at 600 dpi.
/// 24      4     zero24                     u32le  Zero.
/// 28      2     printableHeightPoints      u16le  Printable height and width in points, 767 by 587 for
///                                                 Letter with 0.18-inch margins.
/// 30      2     printableWidthPoints       u16le  Printable height and width in points, 767 by 587 for
///                                                 Letter with 0.18-inch margins.
/// 32      4     pixelsPerPoint             f32le  Printer pixels per point: 8.333 for 600 dpi, 4.167 for
///                                                 300, 1.0 for 72.
/// 36      4     unknown36                         00 4e 00 08 in 2111 files, 00 4e 00 09 in 667; role TODO.
/// 40      8     unknown40                         A big-endian 2, 8 or 16, then 0 or 1; roles TODO.
/// 48      28    zero48                            Zero.
/// 76      16    unknown76                         Zero, or the f32s 2.0, 1.0, 1.0, 1.0 in 11 files; roles
///                                                 TODO.
/// 92      4     marginTop                  f32le  Margins in inches: top, left, bottom, right.
/// 96      4     marginLeft                 f32le  Margins in inches: top, left, bottom, right.
/// 100     4     marginBottom               f32le  Margins in inches: top, left, bottom, right.
/// 104     4     marginRight                f32le  Margins in inches: top, left, bottom, right.
/// 108     4     unknown108                        Zero in all but one file.
/// 112     2     printableHeightPointsAgain u16le  Repeats the height at 28 in all but one file.
/// 114     2     printableWidthPointsAgain  u16le  Repeats the width at 30 in all but one file.
/// 116     4     half116                    f32le  0.5 in every file.
/// 120     8     zero120                           Zero.
/// 128     rest  extra                      u32[]? One or two words in 103 LabVIEW 2012 files; roles TODO.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';

final class ViPrintRecord extends ByteRecord {
  ViPrintRecord(Uint8List bytes) : super(bytes, layout) {
    assert(view.lengthInBytes % 4 == 0, 'PRT is whole u32 words');
  }

  int get length => view.lengthInBytes ~/ 4;

  /// The record as u32 words, read little-endian.
  int operator [](int index) => view.getUint32(4 * index, Endian.little);

  /// Printable height and width in printer pixels, 6392 by 4892 for Letter at 600 dpi.
  (int, int) get printablePixels => (_printableHeightPixels.read(view), _printableWidthPixels.read(view));

  /// Printable height and width in points, 767 by 587 for Letter with 0.18-inch margins.
  (int, int) get printablePoints => (_printableHeightPoints.read(view), _printableWidthPoints.read(view));

  /// Printer pixels per point: 8.333 for 600 dpi, 4.167 for 300, 1.0 for 72.
  double get pixelsPerPoint => _pixelsPerPoint.read(view);

  /// Margins in inches: top, left, bottom, right.
  (double, double, double, double) get margins =>
      (_marginTop.read(view), _marginLeft.read(view), _marginBottom.read(view), _marginRight.read(view));

  /// Paper width and height in inches: the printable points over 72 plus the margins.
  (double, double) get paperInches {
    final (height, width) = printablePoints;
    final (top, left, bottom, right) = margins;
    return (width / 72 + left + right, height / 72 + top + bottom);
  }

  /// Zero.
  int get zero0 => _zero0.read(view);

  /// Always 1.
  int get one4 => _one4.read(view);

  /// Two words, zero in all but 37 files; roles TODO.
  Uint8List get unknown8 => _unknown8.read(view);

  /// Zero.
  int get zero16 => _zero16.read(view);

  /// Zero.
  int get zero24 => _zero24.read(view);

  /// 00 4e 00 08 in 2111 files, 00 4e 00 09 in 667; role TODO.
  Uint8List get unknown36 => _unknown36.read(view);

  /// A big-endian 2, 8 or 16, then 0 or 1; roles TODO.
  Uint8List get unknown40 => _unknown40.read(view);

  /// Zero.
  Uint8List get zero48 => _zero48.read(view);

  /// Zero, or the f32s 2.0, 1.0, 1.0, 1.0 in 11 files; roles TODO.
  Uint8List get unknown76 => _unknown76.read(view);

  /// Zero in all but one file.
  Uint8List get unknown108 => _unknown108.read(view);

  /// Repeats the height and width at 28 and 30 in all but one file.
  (int, int) get printablePointsAgain =>
      (_printableHeightPointsAgain.read(view), _printableWidthPointsAgain.read(view));

  /// 0.5 in every file.
  double get half116 => _half116.read(view);

  /// Zero.
  Uint8List get zero120 => _zero120.read(view);

  /// One or two words in 103 LabVIEW 2012 files; roles TODO.
  List<int> get extra => _extra.read(view);

  /// The record of the given fields; a null zero run stays zero, and a null repeated height or
  /// width repeats the printable points.
  static Uint8List encode({
    required int zero0,
    required int one4,
    required List<int> unknown8,
    required int zero16,
    required int printableHeightPixels,
    required int printableWidthPixels,
    required int zero24,
    required int printableHeightPoints,
    required int printableWidthPoints,
    required double pixelsPerPoint,
    required List<int> unknown36,
    required List<int> unknown40,
    List<int>? zero48,
    required List<int> unknown76,
    required double marginTop,
    required double marginLeft,
    required double marginBottom,
    required double marginRight,
    required List<int> unknown108,
    int? printableHeightPointsAgain,
    int? printableWidthPointsAgain,
    required double half116,
    List<int>? zero120,
    List<int> extra = const [],
  }) {
    final out = Uint8List(_extra.offset + _extra.wordSize * extra.length);
    final view = ByteData.sublistView(out);
    _zero0.write(view, zero0);
    _one4.write(view, one4);
    _unknown8.write(view, unknown8);
    _zero16.write(view, zero16);
    _printableHeightPixels.write(view, printableHeightPixels);
    _printableWidthPixels.write(view, printableWidthPixels);
    _zero24.write(view, zero24);
    _printableHeightPoints.write(view, printableHeightPoints);
    _printableWidthPoints.write(view, printableWidthPoints);
    _pixelsPerPoint.write(view, pixelsPerPoint);
    _unknown36.write(view, unknown36);
    _unknown40.write(view, unknown40);
    if (zero48 != null) _zero48.write(view, zero48);
    _unknown76.write(view, unknown76);
    _marginTop.write(view, marginTop);
    _marginLeft.write(view, marginLeft);
    _marginBottom.write(view, marginBottom);
    _marginRight.write(view, marginRight);
    _unknown108.write(view, unknown108);
    _printableHeightPointsAgain.write(view, printableHeightPointsAgain ?? printableHeightPoints);
    _printableWidthPointsAgain.write(view, printableWidthPointsAgain ?? printableWidthPoints);
    _half116.write(view, half116);
    if (zero120 != null) _zero120.write(view, zero120);
    _extra.write(view, extra);
    return out;
  }

  // dart format off
  static const _zero0 = U32(0, endian: Endian.little); // Zero.
  static const _one4 = U32(4, endian: Endian.little); // Always 1.
  static const _unknown8 = Unknown(8, size: 8); // Two words, zero in all but 37 files; roles TODO.
  static const _zero16 = U32(16, endian: Endian.little); // Zero.
  static const _printableHeightPixels = U16(20, endian: Endian.little);
  static const _printableWidthPixels = U16(22, endian: Endian.little);
  static const _zero24 = U32(24, endian: Endian.little); // Zero.
  static const _printableHeightPoints = U16(28, endian: Endian.little);
  static const _printableWidthPoints = U16(30, endian: Endian.little);
  static const _pixelsPerPoint = F32(32, endian: Endian.little);
  static const _unknown36 = Unknown(36, size: 4); // 00 4e 00 08 in 2111 files, 00 4e 00 09 in 667; role TODO.
  static const _unknown40 = Unknown(40, size: 8); // A big-endian 2, 8 or 16, then 0 or 1; roles TODO.
  static const _zero48 = Unknown(48, size: 28); // Zero.
  static const _unknown76 = Unknown(76, size: 16); // Zero, or the f32s 2.0, 1.0, 1.0, 1.0 in 11 files; roles TODO.
  static const _marginTop = F32(92, endian: Endian.little);
  static const _marginLeft = F32(96, endian: Endian.little);
  static const _marginBottom = F32(100, endian: Endian.little);
  static const _marginRight = F32(104, endian: Endian.little);
  static const _unknown108 = Unknown(108, size: 4); // Zero in all but one file.
  static const _printableHeightPointsAgain = U16(112, endian: Endian.little); // Repeats the height at 28 in all but one file.
  static const _printableWidthPointsAgain = U16(114, endian: Endian.little); // Repeats the width at 30 in all but one file.
  static const _half116 = F32(116, endian: Endian.little); // 0.5 in every file.
  static const _zero120 = Unknown(120, size: 8); // Zero.
  static const _extra = U32List(128, optional: true); // One or two words in 103 LabVIEW 2012 files; roles TODO.

  static const layout = ByteLayout([_zero0, _one4, _unknown8, _zero16, _printableHeightPixels, _printableWidthPixels, _zero24, _printableHeightPoints, _printableWidthPoints, _pixelsPerPoint, _unknown36, _unknown40, _zero48, _unknown76, _marginTop, _marginLeft, _marginBottom, _marginRight, _unknown108, _printableHeightPointsAgain, _printableWidthPointsAgain, _half116, _zero120, _extra]);
  // dart format on
}
