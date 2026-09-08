import 'dart:typed_data';

import 'seq_ini.dart';

enum SeqFormat {
  xml,

  binary,

  ini,

  unknown
  ;

  bool get isText => this == xml || this == ini;
}

const _tof1 = [0x54, 0x4f, 0x46, 0x31];
const _utf8Bom = [0xef, 0xbb, 0xbf];

const _formatSniffLen = 4096;

const _headerScanLen = 8192;

enum Ascii {
  tab(0x09),
  lineFeed(0x0a),
  carriageReturn(0x0d),

  space(0x20),

  dot(0x2e),

  lessThan(0x3c),

  leftBracket(0x5b),

  tilde(0x7e),

  nonAscii(0x80),

  latin1Start(0xa0),

  latin1End(0xff)
  ;

  const Ascii(this.code);
  final int code;
}

enum TofHeaderField {
  fileType(0x0a),

  productName(0x40),

  // TODO: the three version-slot offsets are not verified.
  productVersion(0x72),

  compatibleVersion(0xa4),

  buildVersion(0xd6)
  ;

  const TofHeaderField(this.offset);

  final int offset;
}

SeqFormat detectSeqFormat(Uint8List bytes) {
  if (_startsWith(bytes, _tof1)) return SeqFormat.binary;

  var i = _startsWith(bytes, _utf8Bom) ? 3 : 0;
  while (i < bytes.length && _isAsciiWs(bytes[i])) {
    i++;
  }
  if (i < bytes.length) {
    final byte = bytes[i];
    if (byte == Ascii.lessThan.code) {
      final head = _asciiPeek(bytes, i, _formatSniffLen).toLowerCase();
      if (head.startsWith('<?xml') || head.contains('<teststandfileheader')) {
        return SeqFormat.xml;
      }
    } else if (byte == Ascii.leftBracket.code) {
      final head = _asciiPeek(bytes, i, _formatSniffLen);
      if (head.toLowerCase().contains('teststand')) {
        return SeqFormat.ini;
      }
    }
  }
  return SeqFormat.unknown;
}

class SeqFileHeader {
  const SeqFileHeader({
    required this.format,
    this.fileType,
    this.productName,
    this.fileVersion,
  });

  final SeqFormat format;

  final String? fileType;

  final String? productName;

  final String? fileVersion;

  @override
  String toString() =>
      'SeqFileHeader($format, type=$fileType, '
      'product=$productName, version=$fileVersion)';
}

RegExp _attrPattern(String name) => RegExp("\\s$name=['\"]([^'\"]*)['\"]");

final _typeAttr = _attrPattern('type');
final _fileVersionAttr = _attrPattern('fileversion');
final _productNameAttr = _attrPattern('productname');

SeqFileHeader detectSeqHeader(Uint8List bytes) {
  final fmt = detectSeqFormat(bytes);
  switch (fmt) {
    case SeqFormat.xml:
      final head = _asciiPeek(bytes, 0, _headerScanLen);
      String? attr(RegExp pattern) => pattern.firstMatch(head)?.group(1);
      return SeqFileHeader(
        format: fmt,
        fileType: attr(_typeAttr),
        productName: attr(_productNameAttr),
        fileVersion: attr(_fileVersionAttr),
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

bool _startsWith(Uint8List bytes, List<int> sig) {
  if (bytes.length < sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (bytes[i] != sig[i]) return false;
  }
  return true;
}

bool _isAsciiWs(int byte) =>
    byte == Ascii.space.code ||
    byte == Ascii.tab.code ||
    byte == Ascii.lineFeed.code ||
    byte == Ascii.carriageReturn.code;

String _asciiPeek(Uint8List bytes, int start, int len) {
  final end = (start + len) < bytes.length ? (start + len) : bytes.length;
  final sb = StringBuffer();
  for (var i = start; i < end; i++) {
    final byte = bytes[i];
    sb.writeCharCode(byte < Ascii.nonAscii.code ? byte : Ascii.dot.code);
  }
  return sb.toString();
}

typedef BinaryString = ({int offset, String text});

bool isBinaryPrintable(int byte) =>
    (byte >= Ascii.space.code && byte <= Ascii.tilde.code) ||
    (byte >= Ascii.latin1Start.code && byte <= Ascii.latin1End.code);

List<BinaryString> binaryStrings(Uint8List bytes, {int minLength = 4}) {
  final out = <BinaryString>[];
  final sb = StringBuffer();
  var start = 0;
  void flush() {
    if (sb.length >= minLength) out.add((offset: start, text: sb.toString()));
    sb.clear();
  }

  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    if (isBinaryPrintable(byte)) {
      if (sb.isEmpty) start = i;
      sb.writeCharCode(byte);
    } else {
      flush();
    }
  }
  flush();
  return out;
}

String? _cString(Uint8List bytes, int start) {
  final sb = StringBuffer();
  for (var i = start; i < bytes.length && bytes[i] != 0; i++) {
    if (bytes[i] < Ascii.space.code || bytes[i] > Ascii.tilde.code) {
      break;
    }
    sb.writeCharCode(bytes[i]);
  }
  return sb.isEmpty ? null : sb.toString();
}
