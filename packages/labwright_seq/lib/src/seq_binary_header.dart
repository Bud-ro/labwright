/// `TOF1` container: the fixed header in front of a zlib-deflated body.
///
/// ```text
/// offset  size  field               type      meaning
/// 0x000   4     magic               'TOF1'
/// 0x004   6     reservedA           u8[6]     zero in every corpus file
/// 0x00a   50    fileType            cstr      'SequenceFile', NUL padded
/// 0x03c   4     fileVersion         u32 LE    the XML `fileversion` number (962 = TestStand 2021 SP1)
/// 0x040   50    productName         cstr      'TestStand'
/// 0x072   50    productVersion      cstr      '2021 SP1 (21.1.0.49154)'
/// 0x0a4   50    compatibleVersion   cstr      '21.0.0.0'
/// 0x0d6   50    buildVersion        cstr      '21.0.0.49156'
/// 0x108   4     recordRegionLength  u32 LE    offset of the string pool count inside the inflated body
/// 0x10c   4     reservedB           u32       zero in every corpus file
/// 0x110   1024  savedPath           cstr      the path the file was saved to; empty since TestStand 2014
/// 0x510   4     bodyMarker          'PMCZ'
/// 0x514   4     inflatedLength      u32 LE    byte length of the inflated body
/// 0x518   …     body                zlib      deflated body, runs to the end of the file
/// ```
library;

import 'dart:typed_data';

import 'seq_format.dart';

/// Fixed-offset fields of the `TOF1` header; [size] is the field's byte width, 0 for the open-ended body.
enum Tof1HeaderField {
  /// The four ASCII bytes `TOF1`.
  magic(0x000, 4),

  /// Six bytes, zero in every corpus file.
  reservedA(0x004, 6),

  /// NUL-padded file type, `SequenceFile` in every corpus file.
  fileType(0x00a, 50),

  /// Little-endian file format version; the same number XML files carry as `fileversion`.
  fileVersion(0x03c, 4),

  /// NUL-padded product name.
  productName(0x040, 50),

  /// NUL-padded product version, e.g. `2021 SP1 (21.1.0.49154)`.
  productVersion(0x072, 50),

  /// NUL-padded oldest compatible engine version, e.g. `21.0.0.0`.
  compatibleVersion(0x0a4, 50),

  /// NUL-padded build version, e.g. `21.0.0.49156`.
  buildVersion(0x0d6, 50),

  /// Offset, inside the inflated body, of the string-pool count word; everything before it is the record region.
  recordRegionLength(0x108, 4),

  /// Four bytes, zero in every corpus file.
  reservedB(0x10c, 4),

  /// NUL-padded path the file was last saved to; files written by TestStand 2014 and later leave it empty.
  savedPath(0x110, 1024),

  /// The four ASCII bytes `PMCZ` that introduce the deflated body.
  bodyMarker(0x510, 4),

  /// Little-endian byte length of the inflated body.
  inflatedLength(0x514, 4),

  /// The zlib stream; it runs to the end of the file.
  body(0x518, 0);

  const Tof1HeaderField(this.offset, this.size);

  final int offset;

  final int size;

  int get end => offset + size;
}

/// Format generations of the record grammar, keyed by the header's [Tof1Header.fileVersion].
///
/// Later generations add fields; everything else in the grammar is shared.
enum Tof1Generation {
  /// TestStand 4.x (fileversion 577 in the corpus): 32-bit type timestamps and no protection block in a typedef.
  ts4(0),

  /// TestStand 2013 (fileversion 755): a typedef carries the protection block (two optional digests).
  ts2013(755),

  /// TestStand 2014 and later (fileversion 773 and up): type timestamps widen to 64 bits.
  ts2014(773);

  const Tof1Generation(this.minFileVersion);

  /// The smallest header `fileVersion` written with this generation's layout.
  final int minFileVersion;

  bool get hasProtectionBlock => this != ts4;

  bool get hasWideTimestamp => this == ts2014;

  static Tof1Generation of(int fileVersion) {
    var found = ts4;
    for (final generation in values) {
      if (fileVersion >= generation.minFileVersion) found = generation;
    }
    return found;
  }
}

const _tof1Magic = 0x31464f54;

const _bodyMarker = 0x5a434d50;

/// The parsed fixed header of a `TOF1` file.
final class Tof1Header {
  const Tof1Header({
    required this.fileType,
    required this.fileVersion,
    required this.productName,
    required this.productVersion,
    required this.compatibleVersion,
    required this.buildVersion,
    required this.recordRegionLength,
    required this.savedPath,
    required this.inflatedLength,
    required this.hasBodyMarker,
  });

  /// Parses the header; null when the bytes are too short or do not start with `TOF1`.
  static Tof1Header? parse(Uint8List bytes) {
    if (bytes.length < Tof1HeaderField.body.offset) return null;
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(Tof1HeaderField.magic.offset, Endian.little) != _tof1Magic) return null;
    return Tof1Header(
      fileType: _cString(bytes, Tof1HeaderField.fileType),
      fileVersion: view.getUint32(Tof1HeaderField.fileVersion.offset, Endian.little),
      productName: _cString(bytes, Tof1HeaderField.productName),
      productVersion: _cString(bytes, Tof1HeaderField.productVersion),
      compatibleVersion: _cString(bytes, Tof1HeaderField.compatibleVersion),
      buildVersion: _cString(bytes, Tof1HeaderField.buildVersion),
      recordRegionLength: view.getUint32(Tof1HeaderField.recordRegionLength.offset, Endian.little),
      savedPath: _cString(bytes, Tof1HeaderField.savedPath),
      inflatedLength: view.getUint32(Tof1HeaderField.inflatedLength.offset, Endian.little),
      hasBodyMarker: view.getUint32(Tof1HeaderField.bodyMarker.offset, Endian.little) == _bodyMarker,
    );
  }

  final String fileType;

  final int fileVersion;

  final String productName;

  final String productVersion;

  final String compatibleVersion;

  final String buildVersion;

  final int recordRegionLength;

  final String savedPath;

  final int inflatedLength;

  final bool hasBodyMarker;

  Tof1Generation get generation => Tof1Generation.of(fileVersion);

  /// The header's string fields as XML `teststandfileheader` attributes.
  Map<String, String> get rootAttributes => {
    'type': fileType,
    'fileversion': '$fileVersion',
    'productname': productName,
    'productversion': productVersion,
    'compatibleversion': compatibleVersion,
    'buildversion': buildVersion,
  };

  SeqFileHeader toSeqFileHeader() => SeqFileHeader(
    format: SeqFormat.binary,
    fileType: fileType.isEmpty ? null : fileType,
    productName: productName.isEmpty ? null : productName,
    fileVersion: '$fileVersion',
  );

  /// Byte ranges of the header whose purpose is known, as `(start, end, decoded)`;
  /// the reserved zero ranges and NUL padding count as known-purpose plumbing.
  static List<(int, int, bool)> classify(Uint8List bytes) {
    final spans = <(int, int, bool)>[];
    for (final field in Tof1HeaderField.values) {
      if (field == Tof1HeaderField.body) break;
      switch (field) {
        case Tof1HeaderField.reservedA || Tof1HeaderField.reservedB:
          spans.add((field.offset, field.end, false));
        case Tof1HeaderField.fileType ||
            Tof1HeaderField.productName ||
            Tof1HeaderField.productVersion ||
            Tof1HeaderField.compatibleVersion ||
            Tof1HeaderField.buildVersion ||
            Tof1HeaderField.savedPath:
          final textEnd = _cStringEnd(bytes, field);
          spans.add((field.offset, textEnd, true));
          if (textEnd < field.end) spans.add((textEnd, field.end, false));
        default:
          spans.add((field.offset, field.end, true));
      }
    }
    return spans;
  }

  static int _cStringEnd(Uint8List bytes, Tof1HeaderField field) {
    var end = field.offset;
    while (end < field.end && bytes[end] != 0) {
      end++;
    }
    return end;
  }

  static String _cString(Uint8List bytes, Tof1HeaderField field) =>
      String.fromCharCodes(bytes, field.offset, _cStringEnd(bytes, field));
}
