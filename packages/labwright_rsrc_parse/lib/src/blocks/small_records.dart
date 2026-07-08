/// Decoders for the small fixed/near-fixed record blocks (passwords,
/// signatures, section markers, print/icon records, image envelopes, text
/// records). All total; every field claim is corpus-verified and anything not
/// yet decoded says so.
library;

import 'dart:typed_data';

String _hexOf(Uint8List bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Inverse of [_hexOf]: packs a lowercase hex string back into its bytes. The
/// digest/signature models store their opaque value as hex, so [serialize]
/// reconstructs the exact on-disk bytes from that faithful encoding.
Uint8List _bytesFromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

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

  /// Re-emits the record: the password digest followed by the derived digests,
  /// 16 bytes each. Reproduces the stored body exactly (the digests are the
  /// whole block; each is an opaque identity value retained verbatim).
  Uint8List serialize() {
    final digests = [passwordHash, ...extraHashes];
    final out = Uint8List(digests.length * 16);
    for (var i = 0; i < digests.length; i++) {
      out.setRange(i * 16, i * 16 + 16, _bytesFromHex(digests[i]));
    }
    return out;
  }
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

/// A decoded 16-byte signature block (`RTSG` run-time signature, `OBSG` object
/// signature, `CCSG` compiled-code signature, and the signature half of
/// `SCSR`): an opaque identity value. The *format* (a single 16-byte
/// digest/GUID) is decoded; the derivation is not.
class ViSignature {
  const ViSignature({required this.hex});
  final String hex;

  /// Re-emits the 16 signature bytes (the whole block is this opaque value).
  Uint8List serialize() => _bytesFromHex(hex);
}

/// Decodes a 16-byte signature block (`RTSG`, `OBSG`, `CCSG`); null unless
/// exactly 16 bytes.
ViSignature? decodeRuntimeSignature(Uint8List bytes) => bytes.length == 16 ? ViSignature(hex: _hexOf(bytes)) : null;

/// A decoded `SCSR` record: a u32 marker (0x01000000 across the corpus) plus a
/// 16-byte signature.
class ViScsrRecord {
  const ViScsrRecord({required this.marker, required this.signature});
  final int marker;
  final ViSignature signature;

  /// Re-emits `[u32 marker][16-byte signature]` — the 20-byte record.
  Uint8List serialize() {
    final out = Uint8List(20);
    ByteData.sublistView(out).setUint32(0, marker);
    out.setRange(4, 20, signature.serialize());
    return out;
  }
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
  /// corpus-sample geometry; not confirmed against a rendering).
  final List<int> words;

  /// Re-emits the six big-endian u16 fields — the 12-byte record.
  Uint8List serialize() {
    final out = Uint8List(12);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < 6; i++) {
      d.setUint16(2 * i, words[i]);
    }
    return out;
  }
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

  /// Re-emits the marker as one big-endian u32, plus the second word when the
  /// 8-byte form carries one — reproducing the stored body.
  Uint8List serialize() {
    final extra = extraWord;
    final out = Uint8List(extra == null ? 4 : 8);
    final d = ByteData.sublistView(out);
    d.setUint32(0, value);
    if (extra != null) d.setUint32(4, extra);
    return out;
  }
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

  /// Re-emits the 4-byte big-endian u32.
  Uint8List serialize() {
    final out = Uint8List(4);
    ByteData.sublistView(out).setUint32(0, value);
    return out;
  }
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

  /// Re-emits the big-endian u32 words in order — the whole record.
  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      d.setUint32(i * 4, words[i]);
    }
    return out;
  }
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

/// A decoded `TITL` VI-title record retained losslessly: a `u8` length prefix
/// followed by exactly that many text bytes (the record is `1 + length` bytes).
/// Unlike [decodeTitle] the [text] bytes are kept verbatim — non-printable bytes
/// survive — so [serialize] reproduces the record exactly.
class ViTitleRaw {
  const ViTitleRaw({required this.text});
  final Uint8List text;

  /// Re-emits `[u8 length][text]` — the whole record.
  Uint8List serialize() {
    final out = Uint8List(1 + text.length);
    out[0] = text.length;
    out.setRange(1, out.length, text);
    return out;
  }
}

/// Decodes a `TITL` record losslessly; null unless the `u8` length prefix names
/// exactly the remaining bytes (`1 + length == body length`).
ViTitleRaw? decodeTitleRaw(Uint8List bytes) {
  if (bytes.isEmpty || 1 + bytes[0] != bytes.length) return null;
  return ViTitleRaw(text: Uint8List.sublistView(bytes, 1));
}

/// A decoded fixed-size all-zero constant record (`GCPR` 13 B, `VPDP` 4 B):
/// bodies that are byte-constant (all zero) across the whole corpus. Decoding =
/// verifying the expected constant; [matchesCorpusConstant] is false for a
/// never-seen non-zero variant so drift is loud, not silent.
class ViConstantRecord {
  const ViConstantRecord({required this.length, required this.matchesCorpusConstant});
  final int length;
  final bool matchesCorpusConstant;

  /// Re-emits the all-zero constant body when this record matched it, else null
  /// (a never-seen non-zero variant is not reconstructed from this summary).
  /// The decoders set [matchesCorpusConstant] only for an all-zero body, so the
  /// emitted zeros reproduce it exactly.
  Uint8List? serialize() => matchesCorpusConstant ? Uint8List(length) : null;
}

/// Decodes a `GCPR` record (13 zero bytes across the corpus).
ViConstantRecord? decodeGcprRecord(Uint8List bytes) {
  if (bytes.length != 13) return null;
  return ViConstantRecord(
    length: 13,
    matchesCorpusConstant: bytes.every((b) => b == 0),
  );
}

/// Decodes a `VPDP` record (4 zero bytes across the corpus).
ViConstantRecord? decodeVpdpRecord(Uint8List bytes) {
  if (bytes.length != 4) return null;
  return ViConstantRecord(
    length: 4,
    matchesCorpusConstant: bytes.every((b) => b == 0),
  );
}

/// A decoded big-endian `u32` **word grid**: the block body read as a run of
/// big-endian `u32` words. `DLDR`, `CNST`, and `LPIN` bodies are word grids —
/// `DLDR` a fixed seven-word grid (its first word is 1 in 3470/3471 corpus
/// instances, the remaining words are per-VI), `CNST` and `LPIN` variable-length
/// grids of offset-like values. The words' semantics are not decoded; retaining
/// them re-emits the body exactly.
class ViWordGrid {
  const ViWordGrid({required this.words});
  final List<int> words;

  /// Re-emits the big-endian `u32` words in order — the whole body.
  Uint8List serialize() {
    final out = Uint8List(words.length * 4);
    final d = ByteData.sublistView(out);
    for (var i = 0; i < words.length; i++) {
      d.setUint32(i * 4, words[i]);
    }
    return out;
  }
}

/// Decodes a big-endian `u32` word grid; null unless the body is a non-empty
/// whole number of `u32` words. When [words] is non-null the body must be
/// exactly that many words, so an off-size variant stays copied rather than
/// silently reshaped.
ViWordGrid? decodeWordGrid(Uint8List bytes, {int? words}) {
  if (bytes.isEmpty || bytes.length % 4 != 0) return null;
  if (words != null && bytes.length != words * 4) return null;
  final view = ByteData.sublistView(bytes);
  return ViWordGrid(words: [for (var at = 0; at < bytes.length; at += 4) view.getUint32(at)]);
}

/// Decodes a `DLDR` record as its fixed seven-word `u32` grid; null unless
/// exactly 28 bytes.
ViWordGrid? decodeDldrRecord(Uint8List bytes) => decodeWordGrid(bytes, words: 7);

/// A decoded `CPD2` connector-pane-data record: a single big-endian `u16` (a
/// fixed 2-byte body across the corpus). Its meaning is not decoded; retaining
/// the value re-emits the body.
class ViU16Record {
  const ViU16Record({required this.value});
  final int value;

  /// Re-emits the 2-byte big-endian `u16`.
  Uint8List serialize() {
    final out = Uint8List(2);
    ByteData.sublistView(out).setUint16(0, value);
    return out;
  }
}

/// Decodes a `CPD2` record; null unless exactly 2 bytes.
ViU16Record? decodeCpd2Record(Uint8List bytes) =>
    bytes.length == 2 ? ViU16Record(value: ByteData.sublistView(bytes).getUint16(0)) : null;

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
