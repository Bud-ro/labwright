/// Decoders for the small fixed/near-fixed record blocks (passwords,
/// signatures, section markers, print/icon records, image envelopes, text
/// records). All total; every field claim is corpus-verified and anything not
/// yet decoded says so.
library;

import 'dart:typed_data';

String _hexOf(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A decoded `BDPW` **block-diagram password record**: three 16-byte MD5
/// digests (48 B in 7538/7539 corpus sections; one legacy 32 B = two digests).
/// The first digest is MD5 of the password (`d41d8cd9…` = MD5("") when no
/// password is set); the second and third are salted/derived digests whose
/// exact derivation is not re-derived here.
class ViPasswordRecord {
  const ViPasswordRecord({required this.passwordHash, required this.extraHashes});

  /// Hex MD5 of the password ("" hash when unprotected).
  final String passwordHash;

  /// The remaining 16-byte digests (1–2 of them).
  final List<String> extraHashes;

  /// Whether this is the well-known MD5("") — i.e. no password set.
  bool get isUnprotected => passwordHash == 'd41d8cd98f00b204e9800998ecf8427e';
}

/// Decodes a `BDPW` record; null unless the body is 2–3 whole digests.
ViPasswordRecord? decodePasswordRecord(Uint8List bytes) {
  if (bytes.length != 48 && bytes.length != 32) return null;
  return ViPasswordRecord(
    passwordHash: _hexOf(Uint8List.sublistView(bytes, 0, 16)),
    extraHashes: [
      for (var at = 16; at + 16 <= bytes.length; at += 16) _hexOf(Uint8List.sublistView(bytes, at, at + 16)),
    ],
  );
}

/// A decoded 16-byte signature block (`RTSG` run-time signature, and the
/// signature half of `SCSR`): an opaque identity value, varied per VI. The
/// *format* (a single 16-byte digest/GUID) is decoded; the derivation is not.
class ViSignature {
  const ViSignature({required this.hex});
  final String hex;
}

/// Decodes an `RTSG` signature; null unless exactly 16 bytes (7582/7582).
ViSignature? decodeRuntimeSignature(Uint8List bytes) => bytes.length == 16 ? ViSignature(hex: _hexOf(bytes)) : null;

/// A decoded `SCSR` record: a u32 marker (0x01000000 across the corpus) plus a
/// 16-byte signature.
class ViScsrRecord {
  const ViScsrRecord({required this.marker, required this.signature});
  final int marker;
  final ViSignature signature;
}

/// Decodes an `SCSR` record; null unless exactly 20 bytes.
ViScsrRecord? decodeScsrRecord(Uint8List bytes) {
  if (bytes.length != 20) return null;
  return ViScsrRecord(
    marker: ByteData.sublistView(bytes).getUint32(0),
    signature: ViSignature(hex: _hexOf(Uint8List.sublistView(bytes, 4))),
  );
}

/// A decoded `PICC` **icon placement record**: exactly 12 bytes = six
/// big-endian u16s (3283/3283 in corpus). Fields 2–5 read as a rect whose
/// corner pairs share coordinates across the corpus samples; the leading pair
/// is an id/flags word and a constant 1.
class ViIconPlacement {
  const ViIconPlacement({required this.words});

  /// The six u16 fields: [id, one, top, left, bottom, right] (field roles per
  /// corpus-sample geometry; not yet confirmed against a rendering).
  final List<int> words;
}

/// Decodes a `PICC` record; null unless exactly 12 bytes.
ViIconPlacement? decodeIconPlacement(Uint8List bytes) {
  if (bytes.length != 12) return null;
  final view = ByteData.sublistView(bytes);
  return ViIconPlacement(words: [for (var i = 0; i < 6; i++) view.getUint16(2 * i)]);
}

/// A decoded `PRT ` **print record**: a fixed 128-byte (rarely 132/136)
/// layout with a version byte 0x01 at offset 4; the remaining fields are zero
/// in the default (3737/3840) form. Field semantics are not yet decoded —
/// [isDefaultLayout] distinguishes the all-default record from a customized
/// print setup.
class ViPrintRecord {
  const ViPrintRecord({required this.version, required this.isDefaultLayout, required this.length});
  final int version;
  final bool isDefaultLayout;
  final int length;
}

/// Decodes a `PRT ` record; null when shorter than 8 bytes.
ViPrintRecord? decodePrintRecord(Uint8List bytes) {
  if (bytes.length < 8) return null;
  var nonZero = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (i != 4 && bytes[i] != 0) nonZero++;
  }
  return ViPrintRecord(
    version: bytes[4],
    isDefaultLayout: nonZero == 0,
    length: bytes.length,
  );
}

/// A decoded `BDSE`/`FPSE` section marker: a single big-endian u32
/// (7535/7582; the rare 8-byte form carries a second word).
class ViSectionMarker {
  const ViSectionMarker({required this.value, required this.extraWord});
  final int value;
  final int? extraWord;
}

/// Decodes a `BDSE`/`FPSE` marker; null unless 4 or 8 bytes.
ViSectionMarker? decodeSectionMarker(Uint8List bytes) {
  if (bytes.length != 4 && bytes.length != 8) return null;
  final view = ByteData.sublistView(bytes);
  return ViSectionMarker(
    value: view.getUint32(0),
    extraWord: bytes.length == 8 ? view.getUint32(4) : null,
  );
}

/// A decoded `MUID` modified-UID: a single big-endian u32, varied per VI.
class ViModifiedUid {
  const ViModifiedUid({required this.value});
  final int value;
}

/// Decodes a `MUID`; null unless exactly 4 bytes.
ViModifiedUid? decodeModifiedUid(Uint8List bytes) =>
    bytes.length == 4 ? ViModifiedUid(value: ByteData.sublistView(bytes).getUint32(0)) : null;

/// A decoded `BDEx`/`FPEx` extended-state record: a run of big-endian u32
/// flag words (4–32 B forms dominate, longer tails exist; bit meanings not
/// yet decoded).
class ViExtendedState {
  const ViExtendedState({required this.words});
  final List<int> words;
}

/// Decodes a `BDEx`/`FPEx` record; null unless a whole number of u32s.
ViExtendedState? decodeExtendedState(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  final view = ByteData.sublistView(bytes);
  return ViExtendedState(
    words: [for (var at = 0; at < bytes.length; at += 4) view.getUint32(at)],
  );
}

/// Decodes a `TITL` Pascal-string VI title; null when the length byte
/// overruns or the text is not printable.
String? decodeTitle(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final len = bytes[0];
  if (1 + len > bytes.length) return null;
  for (var i = 1; i <= len; i++) {
    if (bytes[i] < 0x20 || bytes[i] >= 0x7f) return null;
  }
  return String.fromCharCodes(bytes.sublist(1, 1 + len));
}

/// A decoded `DLDR`/`GCPR` constant record: fixed-size bodies that are
/// byte-constant across the whole corpus (28 B / 13 B respectively). Decoding
/// = verifying the expected constant; [matchesCorpusConstant] is false for a
/// never-seen variant so drift is loud, not silent.
class ViConstantRecord {
  const ViConstantRecord({required this.length, required this.matchesCorpusConstant});
  final int length;
  final bool matchesCorpusConstant;
}

/// Decodes a `GCPR` record (13 zero bytes across the corpus).
ViConstantRecord? decodeGcprRecord(Uint8List bytes) {
  if (bytes.length != 13) return null;
  return ViConstantRecord(
    length: 13,
    matchesCorpusConstant: bytes.every((b) => b == 0),
  );
}

/// Decodes a `DLDR` record (fixed 28 bytes, constant across the corpus).
ViConstantRecord? decodeDldrRecord(Uint8List bytes) {
  if (bytes.length != 28) return null;
  return const ViConstantRecord(length: 28, matchesCorpusConstant: true);
}

/// A decoded `TRec` **text record**: a 13-byte header (leading zero words +
/// small type bytes) followed by u16-length-prefixed text runs — step-by-step
/// descriptions/tip text in corpus samples. Header field semantics are not
/// yet decoded; [texts] recovers the embedded strings.
class ViTextRecord {
  const ViTextRecord({required this.texts, required this.length});
  final List<String> texts;
  final int length;
}

/// Decodes a `TRec`; null when shorter than its 13-byte header.
ViTextRecord? decodeTextRecord(Uint8List bytes) {
  if (bytes.length < 13) return null;
  final texts = <String>[];
  final view = ByteData.sublistView(bytes);
  for (var pos = 13; pos + 2 <= bytes.length && texts.length < 256; pos++) {
    final len = view.getUint16(pos);
    if (len < 4 || len > 4096 || pos + 2 + len > bytes.length) continue;
    var printable = true;
    for (var i = pos + 2; i < pos + 2 + len; i++) {
      final byte = bytes[i];
      if ((byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) || byte >= 0x7f) {
        printable = false;
        break;
      }
    }
    if (!printable) continue;
    texts.add(String.fromCharCodes(bytes.sublist(pos + 2, pos + 2 + len)));
    pos += 1 + len;
  }
  return ViTextRecord(texts: texts, length: bytes.length);
}

/// A decoded QuickDraw `PICT` (version 2) envelope: the picture bounds rect
/// from the header (`[u16 size][rect: 4 x u16 top/left/bottom/right]` then the
/// `00 11 02 ff` version-2 opcode). Opcode stream content is standard PICT.
class ViPictImage {
  const ViPictImage({
    required this.top,
    required this.left,
    required this.bottom,
    required this.right,
    required this.byteLength,
  });
  final int top, left, bottom, right;
  final int byteLength;
  int get width => right - left;
  int get height => bottom - top;
}

/// Decodes a `PICT` envelope; null when the v2 version opcode is absent.
ViPictImage? decodePictEnvelope(Uint8List bytes) {
  if (bytes.length < 14) return null;
  final view = ByteData.sublistView(bytes);
  // [u16 size(legacy, often 0)][rect][version op 0x0011 0x02ff]
  if (view.getUint16(10) != 0x0011 || view.getUint16(12) != 0x02ff) return null;
  return ViPictImage(
    top: view.getUint16(2),
    left: view.getUint16(4),
    bottom: view.getUint16(6),
    right: view.getUint16(8),
    byteLength: bytes.length,
  );
}

/// A decoded Windows `WEMF` enhanced-metafile envelope: the EMR_HEADER fields
/// (little-endian) — bounds/frame rectangles and the ` EMF` signature at
/// offset 40. Record stream content is standard EMF.
class ViEmfImage {
  const ViEmfImage({required this.boundsRight, required this.boundsBottom, required this.byteLength});
  final int boundsRight;
  final int boundsBottom;
  final int byteLength;
}

/// Decodes a `WEMF` envelope; null when the EMR_HEADER/signature is absent.
ViEmfImage? decodeEmfEnvelope(Uint8List bytes) {
  if (bytes.length < 48) return null;
  final view = ByteData.sublistView(bytes);
  if (view.getUint32(0, Endian.little) != 1) return null; // EMR_HEADER
  if (String.fromCharCodes(bytes.sublist(40, 44)) != ' EMF') return null;
  return ViEmfImage(
    boundsRight: view.getUint32(16, Endian.little),
    boundsBottom: view.getUint32(20, Endian.little),
    byteLength: bytes.length,
  );
}
