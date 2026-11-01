/// `TOF1` binary sequence files: the fixed header, the zlib-deflated body behind it, and the Windows-1252 code
/// page of the body's strings.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart'
    show ByteLayout, ByteRecord, Bytes, FourCc, U32, Unknown;

import 'seq_format.dart';

/// The four-character codes of a `TOF1` file.
enum Tof1Signature {
  /// Opens the file.
  file('TOF1'),

  /// Introduces the deflated body.
  body('PMCZ');

  const Tof1Signature(this.code);
  final String code;
}

/// Format generations of the record grammar, keyed by the header's [Tof1Header.fileVersion].
///
/// Later generations add fields; everything else in the grammar is shared.
enum Tof1Generation {
  /// TestStand 4.x: 32-bit type timestamps and no protection block in a typedef.
  ts4(0),

  /// TestStand 2013: a typedef carries the protection block (two optional digests).
  ts2013(755),

  /// TestStand 2014 and later: type timestamps widen to 64 bits.
  ts2014(773);

  const Tof1Generation(this.minFileVersion);

  /// The smallest header `fileVersion` decoded with this generation's layout.
  ///
  /// TODO: the exact fileversion at which each layout begins is not yet decoded; each threshold is the oldest
  /// version known to use the layout.
  final int minFileVersion;
  bool get hasProtectionBlock => this != ts4;
  bool get hasWideTimestamp => this == ts2014;
  static Tof1Generation of(int fileVersion) => values.lastWhere((g) => fileVersion >= g.minFileVersion);
}

/// The fixed header of a `TOF1` file; the zlib stream of the body follows it to the end of the file.
final class Tof1Header extends ByteRecord {
  Tof1Header._(Uint8List bytes) : super(Uint8List.sublistView(bytes, 0, size), layout);

  factory Tof1Header.blank() {
    final header = Tof1Header._(Uint8List(size));
    _magic.write(header.view, Tof1Signature.file.code);
    _bodyMarker.write(header.view, Tof1Signature.body.code);
    return header;
  }

  /// The header of [bytes]; null when they are too short or do not start with `TOF1`.
  static Tof1Header? parse(Uint8List bytes) {
    if (bytes.length < size) return null;
    final header = Tof1Header._(bytes);
    return _magic.read(header.view) == Tof1Signature.file.code ? header : null;
  }

  /// NUL-padded file type, e.g. `SequenceFile`.
  String get fileType => _text(_fileType);
  set fileType(String value) => _setText(_fileType, value);

  /// File format version; the same number XML files carry as `fileversion`.
  int get fileVersion => _fileVersion.read(view);
  set fileVersion(int value) => _fileVersion.write(view, value);

  /// NUL-padded product name.
  String get productName => _text(_productName);
  set productName(String value) => _setText(_productName, value);

  /// NUL-padded product version, e.g. `2021 SP1 (21.1.0.49154)`.
  String get productVersion => _text(_productVersion);
  set productVersion(String value) => _setText(_productVersion, value);

  /// NUL-padded oldest compatible engine version, e.g. `21.0.0.0`.
  String get compatibleVersion => _text(_compatibleVersion);

  /// NUL-padded build version, e.g. `21.0.0.49156`.
  String get buildVersion => _text(_buildVersion);

  /// Offset, inside the inflated body, of the string-pool count word; everything before it is the record region.
  int get recordRegionLength => _recordRegionLength.read(view);
  set recordRegionLength(int value) => _recordRegionLength.write(view, value);

  /// NUL-padded path the file was last saved to, or empty.
  String get savedPath => _text(_savedPath);

  bool get hasBodyMarker => _bodyMarker.read(view) == Tof1Signature.body.code;

  /// Byte length of the inflated body.
  int get inflatedLength => _inflatedLength.read(view);
  set inflatedLength(int value) => _inflatedLength.write(view, value);
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

  String _text(Bytes field) {
    final bytes = field.read(view);
    final nul = bytes.indexOf(0);
    return String.fromCharCodes(bytes, 0, nul < 0 ? bytes.length : nul);
  }

  void _setText(Bytes field, String value) {
    assert(value.length < field.size!, 'a ${field.size}-byte field holds ${value.length} characters and a NUL');
    field.read(view)
      ..fillRange(0, field.size!, 0)
      ..setAll(0, value.codeUnits);
  }

  static const _magic = FourCc(0x000);
  static const _reservedA = Unknown(0x004, size: 6);
  static const _fileType = Bytes(0x00a, size: 50);
  static const _fileVersion = U32(0x03c, endian: Endian.little);
  static const _productName = Bytes(0x040, size: 50);
  static const _productVersion = Bytes(0x072, size: 50);
  static const _compatibleVersion = Bytes(0x0a4, size: 50);
  static const _buildVersion = Bytes(0x0d6, size: 50);
  static const _recordRegionLength = U32(0x108, endian: Endian.little);
  static const _reservedB = Unknown(0x10c, size: 4);
  static const _savedPath = Bytes(0x110, size: 1024);
  static const _bodyMarker = FourCc(0x510);
  static const _inflatedLength = U32(0x514, endian: Endian.little);

  static const layout = ByteLayout([
    _magic,
    _reservedA,
    _fileType,
    _fileVersion,
    _productName,
    _productVersion,
    _compatibleVersion,
    _buildVersion,
    _recordRegionLength,
    _reservedB,
    _savedPath,
    _bodyMarker,
    _inflatedLength,
  ]);

  static final int size = layout.size!;
}

const _maxInflatedBytes = 128 * 1024 * 1024;

/// Inflates the body of a `TOF1` file; null unless the header carries the `PMCZ` marker and the stream inflates to
/// exactly the length the header declares.
Uint8List? inflateBinaryBody(Uint8List bytes) {
  final header = Tof1Header.parse(bytes);
  if (header == null || !header.hasBodyMarker || header.inflatedLength > _maxInflatedBytes) return null;
  final filter = RawZLibFilter.inflateFilter();
  final out = BytesBuilder(copy: false);
  try {
    filter.process(bytes, Tof1Header.size, bytes.length);
    for (var chunk = filter.processed(end: true); chunk != null; chunk = filter.processed(end: true)) {
      out.add(chunk);
      if (out.length > header.inflatedLength) return null;
    }
  } on FormatException {
    return null;
  }
  return out.length == header.inflatedLength ? out.takeBytes() : null;
}

/// Code points of the Windows-1252 bytes 0x80–0x9f, indexed by `byte - 0x80`; the five bytes the code page leaves
/// unassigned (0x81, 0x8d, 0x8f, 0x90, 0x9d) map to the C1 control of the same value, as Windows itself decodes
/// them, so every byte sequence decodes and encodes back unchanged. Every other byte is its own code point.
const List<int> _windows1252High = [
  0x20ac, 0x0081, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, //
  0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008d, 0x017d, 0x008f,
  0x0090, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
  0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x009d, 0x017e, 0x0178,
];

const _highStart = 0x80;
const _highEnd = 0xa0;
const _byteLimit = 0x100;

final Map<int, int> _windows1252Encode = {
  for (var i = 0; i < _windows1252High.length; i++) _windows1252High[i]: _highStart + i,
};

/// Decodes [bytes] as Windows-1252, the code page of `TOF1` pool strings.
String decodeWindows1252(Uint8List bytes) {
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    units[i] = byte >= _highStart && byte < _highEnd ? _windows1252High[byte - _highStart] : byte;
  }
  return String.fromCharCodes(units);
}

/// Encodes [text] as Windows-1252; null when it holds a character the code page lacks.
Uint8List? encodeWindows1252(String text) {
  final out = Uint8List(text.length);
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    final byte = unit < _highStart || (unit >= _highEnd && unit < _byteLimit) ? unit : _windows1252Encode[unit];
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
