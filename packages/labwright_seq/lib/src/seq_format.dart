import 'dart:typed_data';

import 'seq_ini.dart';

/// The on-disk encoding of a TestStand file (`.seq`, type palette, etc.).
///
/// TestStand 4.0+ can save a sequence file in three encodings — **binary, XML,
/// INI** — for the *same* logical content (sequences + types + globals). This
/// catalog is the single documented source of truth for telling them apart; each
/// value records how it is recognized and the confidence of that rule (clean-room
/// RE from real files — see `packages/labwright_seq/NOTES.md`).
enum SeqFormat {
  /// XML text: an optional UTF-8 BOM (`EF BB BF`) then `<?xml …?>`, whose root is
  /// `<teststandfileheader type='…' fileversion='…' productname='TestStand'>`.
  /// Text, self-describing, directly parseable. **Confirmed** (M0: NI example
  /// sequences, fileversion 920/962).
  xml,

  /// NI's proprietary flat binary container. Magic = ASCII **`TOF1`** at offset 0
  /// (NOT Microsoft OLE2/CFBF — that earlier guess is ruled out). The file-type
  /// token (e.g. `SequenceFile`) is a NUL-terminated ASCII string at offset 0x0A.
  /// **Confirmed** (M0: real-world + TS2017/2019 example sequences). The record
  /// grammar after the header is not yet decoded.
  binary,

  /// Legacy INI text (TestStand 3.x and earlier; NI has deprecated saving in it).
  /// **Inferred** — recognized heuristically (INI sections + a TestStand marker);
  /// not yet verified against a real sample in the corpus, so treat as low
  /// confidence until one is added.
  ini,

  /// Not recognized as any known TestStand encoding.
  unknown;

  /// True for the two text encodings (viewable without the TestStand engine).
  bool get isText => this == xml || this == ini;
}

const _tof1 = [0x54, 0x4f, 0x46, 0x31];
const _utf8Bom = [0xef, 0xbb, 0xbf];

/// Bytes peeked to sniff the encoding from the header.
const _formatSniffLen = 4096;

/// Bytes read to extract header attributes.
const _headerScanLen = 8192;

/// ASCII byte codes used in format sniffing and string scanning — one documented
/// catalog instead of scattered hex literals.
enum Ascii {
  tab(0x09),
  lineFeed(0x0a),
  carriageReturn(0x0d),

  /// Space — also the lowest printable code.
  space(0x20),

  /// `.` — substituted for non-ASCII bytes when peeking text.
  dot(0x2e),

  /// `<` — XML/markup start.
  lessThan(0x3c),

  /// `[` — INI section start.
  leftBracket(0x5b),

  /// `~` — highest printable code (inclusive).
  tilde(0x7e),

  /// First non-ASCII code (0x20..0x7f are printable; this is the exclusive top).
  nonAscii(0x80),

  /// Lowest Latin-1 high-range printable (`0xa0`, no-break space); `0x7f..0x9f`
  /// (C1 controls / undefined in Latin-1) are not printable.
  latin1Start(0xa0),

  /// Highest Latin-1 printable (`0xff`, `ÿ`).
  latin1End(0xff);

  const Ascii(this.code);
  final int code;
}

/// Byte offsets of the fixed fields in a binary `TOF1` header (verified across
/// the binary corpus, TS2014 layout). Each field is a NUL-terminated ASCII run;
/// the product fields sit in 50-byte NUL-padded slots. One
/// documented catalog replaces scattered offset literals.
enum TofHeaderField {
  /// The file-type token, e.g. `SequenceFile`. Decoded.
  fileType(0x0a),

  /// The product name, e.g. `TestStand`. Decoded.
  productName(0x40),

  // TODO: the following three offsets are candidates from the TS2014 layout but
  // are not yet decoded/verified — do not rely on them until confirmed.
  /// Product-version slot. Not yet decoded/verified.
  productVersion(0x72),

  /// Compatible-version slot. Not yet decoded/verified.
  compatibleVersion(0xa4),

  /// Build-version slot. Not yet decoded/verified.
  buildVersion(0xd6);

  const TofHeaderField(this.offset);

  /// Byte offset of the field from the start of the file.
  final int offset;
}

/// Classifies [bytes] as a TestStand file encoding from its header alone — total
/// over arbitrary input (never throws; returns [SeqFormat.unknown] when unsure).
SeqFormat detectSeqFormat(Uint8List bytes) {
  if (_startsWith(bytes, _tof1)) return SeqFormat.binary;

  var i = _startsWith(bytes, _utf8Bom) ? 3 : 0;
  while (i < bytes.length && _isAsciiWs(bytes[i])) {
    i++;
  }
  if (i < bytes.length) {
    final b = bytes[i];
    if (b == Ascii.lessThan.code) {
      final head = _asciiPeek(bytes, i, _formatSniffLen).toLowerCase();
      if (head.startsWith('<?xml') || head.contains('<teststandfileheader')) {
        return SeqFormat.xml;
      }
    } else if (b == Ascii.leftBracket.code) {
      final head = _asciiPeek(bytes, i, _formatSniffLen);
      if (head.toLowerCase().contains('teststand')) {
        return SeqFormat.ini;
      }
    }
  }
  return SeqFormat.unknown;
}

/// What [detectSeqHeader] recovers from a file header. Fields are null when the
/// encoding doesn't carry them or they aren't yet decoded — never fabricated.
class SeqFileHeader {
  const SeqFileHeader({
    required this.format,
    this.fileType,
    this.productName,
    this.fileVersion,
  });

  final SeqFormat format;

  /// The declared file kind, e.g. `SequenceFile`, `TypePaletteFile`. For [xml]
  /// it's the `type` attribute; for [binary] the NUL-terminated token at 0x0A.
  final String? fileType;

  /// The producing product, e.g. `TestStand` (XML `productname`).
  final String? productName;

  /// The format/engine version stamp, e.g. `920`, `962` (XML `fileversion`).
  final String? fileVersion;

  @override
  String toString() =>
      'SeqFileHeader($format, type=$fileType, '
      'product=$productName, version=$fileVersion)';
}

final _attr = <String, RegExp>{
  'type': RegExp("type=['\"]([^'\"]*)['\"]"),
  'fileversion': RegExp("fileversion=['\"]([^'\"]*)['\"]"),
  'productname': RegExp("productname=['\"]([^'\"]*)['\"]"),
};

/// Reads the header of [bytes] — total over arbitrary input.
SeqFileHeader detectSeqHeader(Uint8List bytes) {
  final fmt = detectSeqFormat(bytes);
  switch (fmt) {
    case SeqFormat.xml:
      final head = _asciiPeek(bytes, 0, _headerScanLen);
      String? attr(String k) => _attr[k]!.firstMatch(head)?.group(1);
      return SeqFileHeader(
        format: fmt,
        fileType: attr('type'),
        productName: attr('productname'),
        fileVersion: attr('fileversion'),
      );
    case SeqFormat.ini:
      return parseIniHeader(_asciiPeek(bytes, 0, _headerScanLen));
    case SeqFormat.binary:
      return SeqFileHeader(
        format: fmt,
        fileType: _cString(bytes, TofHeaderField.fileType.offset),
        productName: _cString(bytes, TofHeaderField.productName.offset),
      );
    case SeqFormat.unknown:
      return const SeqFileHeader(format: SeqFormat.unknown);
  }
}

bool _startsWith(Uint8List b, List<int> sig) {
  if (b.length < sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return false;
  }
  return true;
}

bool _isAsciiWs(int c) =>
    c == Ascii.space.code ||
    c == Ascii.tab.code ||
    c == Ascii.lineFeed.code ||
    c == Ascii.carriageReturn.code;

/// Decodes up to [len] bytes from [start] as ASCII for header sniffing (bytes
/// ≥ 0x80 become '.'), stopping at the buffer end.
String _asciiPeek(Uint8List b, int start, int len) {
  final end = (start + len) < b.length ? (start + len) : b.length;
  final sb = StringBuffer();
  for (var i = start; i < end; i++) {
    final c = b[i];
    sb.writeCharCode(c < Ascii.nonAscii.code ? c : Ascii.dot.code);
  }
  return sb.toString();
}

/// One printable-ASCII run found in a binary file: its byte [offset] and [text].
typedef BinaryString = ({int offset, String text});

/// Whether [c] is a printable text byte for binary string scanning: ASCII
/// `0x20..0x7e` **plus** the Latin-1 high range `0xa0..0xff`. NI stores names,
/// module paths and expressions in the system code page (Latin-1 in the corpus),
/// so non-ASCII letters (e.g. `ü`, `ı`, `ö`) are real text — including them keeps
/// runs like `…\4_Aktif_Güç.vi` intact instead of fragmenting them at the accent.
/// The `0x7f..0x9f` gap (C1 controls / undefined in Latin-1) stays a separator.
bool isBinaryPrintable(int c) =>
    (c >= Ascii.space.code && c <= Ascii.tilde.code) ||
    (c >= Ascii.latin1Start.code && c <= Ascii.latin1End.code);

/// Extracts the printable runs (length ≥ [minLength]) from binary [bytes] — see
/// [isBinaryPrintable] for the byte set (ASCII + Latin-1 high range).
///
/// A reconnaissance primitive for the not-yet-decoded binary `TOF1` container —
/// it surfaces the embedded strings (header fields, names, expressions) **with
/// their offsets** so the record framing can be worked out, without making any
/// structural claim. Total over arbitrary input.
List<BinaryString> binaryStrings(Uint8List bytes, {int minLength = 4}) {
  final out = <BinaryString>[];
  final sb = StringBuffer();
  var start = 0;
  void flush() {
    if (sb.length >= minLength) out.add((offset: start, text: sb.toString()));
    sb.clear();
  }

  for (var i = 0; i < bytes.length; i++) {
    final c = bytes[i];
    if (isBinaryPrintable(c)) {
      if (sb.isEmpty) start = i;
      sb.writeCharCode(c);
    } else {
      flush();
    }
  }
  flush();
  return out;
}

/// Reads a NUL-terminated printable-ASCII string at [start]; null if none.
String? _cString(Uint8List b, int start) {
  final sb = StringBuffer();
  for (var i = start; i < b.length && b[i] != 0; i++) {
    if (b[i] < Ascii.space.code || b[i] > Ascii.tilde.code) {
      break;
    }
    sb.writeCharCode(b[i]);
  }
  return sb.isEmpty ? null : sb.toString();
}
