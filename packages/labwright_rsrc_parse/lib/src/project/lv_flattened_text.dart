import 'dart:typed_data';

/// The text form a library file's `Bin` properties take, such as `NI.LVClass.FlattenedPrivateDataCTL`
/// and `NI.Lib.Icon`: six bits per character, each the character's code less `!` (0x21), most
/// significant first; characters outside `!`..`` ` `` are ignored.
Uint8List lvFlattenedTextBytes(String text) {
  final out = BytesBuilder(copy: false);
  var accumulator = 0, bits = 0;
  for (final unit in text.codeUnits) {
    if (unit < 0x21 || unit > 0x60) continue;
    accumulator = ((accumulator << 6) | (unit - 0x21)) & 0x3fff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.addByte((accumulator >> bits) & 0xff);
    }
  }
  return out.toBytes();
}

/// [bytes] in the text form [lvFlattenedTextBytes] reads, padded with zero bits.
String lvFlattenedText(Uint8List bytes) {
  final out = StringBuffer();
  var accumulator = 0, bits = 0;
  for (final byte in bytes) {
    accumulator = ((accumulator << 8) | byte) & 0x3fff;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      out.writeCharCode(0x21 + ((accumulator >> bits) & 0x3f));
    }
  }
  if (bits > 0) out.writeCharCode(0x21 + ((accumulator << (6 - bits)) & 0x3f));
  return out.toString();
}
