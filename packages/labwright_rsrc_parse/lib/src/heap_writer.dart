/// The **heap-content writer** — the inverse of the heap decoder ([walkHeapBody]
/// / [heapObjectHeaderAt] / [decodeHeapAttr] / [decodeHeapRef] / [c4FrameAt]).
///
/// A VI's block-diagram / front-panel / data-type heaps are stored zlib-deflated;
/// LabVIEW reads them THROUGH zlib, so correctness for these sections is defined
/// at the **inflated-content** level (see `content_exact.dart`): a rewritten heap
/// section is correct iff its inflated bytes match the original's inflated bytes.
/// This writer re-serializes that inflated content from the decoded model.
///
/// Discipline (identical to the block-payload writer): a heap record is
/// **model-sourced** only when its bytes are reconstructed from decoded, typed
/// fields AND the reconstruction reproduces the record's bytes exactly. Every
/// other span — an undecoded record, a lossy-decoded interior (strings/paths/
/// blobs are decoded through a printable filter, so they are NOT byte-faithful),
/// the leading `u32` content-length, and any tail past the walk — is **copied**
/// verbatim. The re-emitted body is therefore byte-identical to the inflated
/// input regardless of how much is modeled (the inflate-content byte-exact law).
///
/// A modeled record is emitted as a **reconstructed header** (rebuilt from the
/// decoded scalar fields and verified against the original bytes) followed, for
/// records whose interior role is identified, by a **byte-faithful retained
/// interior** — the record's own content bytes, carried on the decoded model as a
/// typed field and re-emitted verbatim. Retaining an identified interior verbatim
/// is a legitimate, honest model: the record's role is known even where its inner
/// packing is not decoded, and the re-emission is byte-exact by construction. Only
/// interiors whose role is NOT identified (an unknown-opcode `C4` payload, an
/// odd-shaped rectangle payload, the tail past a walk stop) stay copied.
///
/// Model-sourced record families:
///   * object headers `10/11/12 <tag> 02 fe <u16 kind> fd <u16 oid>` (9 bytes);
///   * group-close markers `08/09/0a/0b <sub>` (2 bytes);
///   * typed references `14..17 <sub> 01 fd <u16 oid>` (6 bytes);
///   * the attribute nibble family `0x/2x/4x/6x/8x/Ex <id> <value>` (integer /
///     RGB / flag widths) and the `Cx <id> 08 <4× s16>` rectangle form —
///     reconstructed from the decoded value;
///   * `C4 <op> <len>` rectangle opcodes (the 8-byte 4× `s16` payload);
///   * `C4` string / string-table / help-text / path / container records —
///     reconstructed `C4 <op> <len>` header plus the retained interior
///     ([HeapRecord.rawText] / [HeapRecord.rawPathBytes] / [HeapRecord.payload]);
///   * `Cx <id> <len>` `f64` / blob / container attributes — reconstructed header
///     plus the retained value bytes ([HeapAttr.rawValueBytes]);
///   * typed-list property / group-open records `<op> <subop> <count> <tag> …` —
///     reconstructed 3-byte framing plus the retained typed-item region.
/// Copied (interior role not identified): unknown-opcode `C4` payloads, odd-shaped
/// rectangle payloads, the leading `u32` content-length, and any walk tail.
library;

import 'dart:typed_data';

import 'blocks/type_pool.dart' show reserializeTypePool, typePoolFrames;
import 'heap.dart';

/// The result of re-serializing one inflated heap body from its decoded model:
/// the re-emitted [bytes] (byte-identical to the input), and the model/copied
/// byte split. [modelBytes] + [copiedBytes] == [bytes].length.
class HeapWriteResult {
  HeapWriteResult({
    required this.bytes,
    required this.modelBytes,
    required this.copiedBytes,
    required this.modelBugs,
  });

  /// The re-emitted inflated heap body — byte-identical to the input.
  final Uint8List bytes;

  /// Bytes emitted from a decoded, typed field (reconstruction verified exact).
  final int modelBytes;

  /// Bytes copied verbatim (undecoded / lossy interiors, the leading `u32`
  /// content-length, and any tail past the record walk).
  final int copiedBytes;

  /// Records whose category is expected to reconstruct losslessly but did not
  /// reproduce the original bytes — a heap-model bug (a dropped/misread field).
  /// The record is copied verbatim so the body stays byte-exact; the count is
  /// surfaced so a regression is loud. Zero for a faithful model.
  final int modelBugs;

  /// Total body length (`modelBytes + copiedBytes`).
  int get bodyBytes => modelBytes + copiedBytes;
}

void _putU16(Uint8List b, int at, int v) {
  b[at] = (v >> 8) & 0xff;
  b[at + 1] = v & 0xff;
}

void _putS16(Uint8List b, int at, int v) {
  b[at] = (v >> 8) & 0xff;
  b[at + 1] = v & 0xff;
}

/// The modeled portion of a heap record: a reconstructed **header** ([prefix],
/// the first [length] bytes, rebuilt from decoded scalar fields) followed by a
/// byte-faithful **retained interior** of [retained] more bytes (the record's
/// identified content, carried on the model and re-emitted verbatim). The bytes
/// past `length + retained` (if any) are an unidentified interior copied verbatim.
/// [length] 0 ⇒ nothing modeled.
class _Modeled {
  const _Modeled(this.prefix, this.length, {this.expected = false, this.retained = 0});

  /// The rebuilt header bytes for `[0, length)` of the record (null when nothing
  /// is modeled).
  final Uint8List? prefix;

  /// How many leading record bytes [prefix] reconstructs (the header).
  final int length;

  /// Whether the header is expected to reconstruct losslessly (so a mismatch is a
  /// model bug, not merely an undecoded span).
  final bool expected;

  /// Bytes immediately after the header that are a byte-faithful retained
  /// interior — modeled verbatim from the record's own content field, needing no
  /// comparison (they are the source bytes). Counted as model only when the
  /// header verifies.
  final int retained;
}

const _Modeled _nothing = _Modeled(null, 0);

/// Whether a `C4` record of [shape] has an interior whose role is identified, so
/// its payload is retained byte-faithfully (modeled) rather than copied: strings
/// / captions / format strings, string tables, help text, `PTH0` paths, and
/// composite clusters. An unknown-opcode payload or an odd-shaped rectangle
/// payload is not identified and stays copied.
bool _c4RetainsInterior(HeapShape shape) => switch (shape) {
  HeapShape.string || HeapShape.stringTable || HeapShape.helpText || HeapShape.path || HeapShape.container => true,
  HeapShape.rectangle || HeapShape.none => false,
};

/// Reconstructs the model prefix of the record at [offset] (lead byte [lead],
/// framed length [spanLength]) in [body]. Returns [_nothing] for a record with
/// no modeled framing.
_Modeled _modelRecord(Uint8List body, int offset, int lead, int spanLength) {
  // Object header — 9 bytes, every one a field or a structural constant.
  final header = heapObjectHeaderAt(body, offset);
  if (header != null) {
    final out = Uint8List(9);
    out[0] = body[offset];
    out[1] = body[offset + 1];
    out[2] = 0x02;
    out[3] = 0xfe;
    _putU16(out, 4, header.kind);
    out[6] = 0xfd;
    _putU16(out, 7, header.oid);
    return _Modeled(out, 9, expected: true);
  }

  // Typed reference `14..17 <sub> 01 fd <u16 oid>` — 6 bytes.
  final ref = decodeHeapRef(body, offset);
  if (ref != null) {
    final out = Uint8List(6);
    out[0] = body[offset];
    out[1] = body[offset + 1];
    out[2] = 0x01;
    out[3] = 0xfd;
    _putU16(out, 4, ref.targetOid);
    return _Modeled(out, 6, expected: true);
  }

  // Group-close marker `08/09/0a/0b <sub>` — the 2-byte positional close.
  if (kHeapGroupCloseLeads.contains(lead) && spanLength == 2) {
    return _Modeled(Uint8List.fromList([body[offset], body[offset + 1]]), 2, expected: true);
  }

  // `C4 <op> <len> <payload>` opcode record.
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(body, offset, '');
    if (rec != null) {
      final headerLen = rec.headerLength;
      // A rectangle opcode carries an 8-byte 4× s16 payload — reconstruct whole.
      if (rec.kind.shape == HeapShape.rectangle && rec.payload.length == 8) {
        final rect = HeapRect.fromPayload(rec.payload);
        if (rect != null) {
          final out = Uint8List(11);
          out[0] = kHeapRecordPrefix;
          out[1] = rec.opcode;
          out[2] = 0x08;
          _putS16(out, 3, rect.top);
          _putS16(out, 5, rect.left);
          _putS16(out, 7, rect.bottom);
          _putS16(out, 9, rect.right);
          return _Modeled(out, 11, expected: true);
        }
      }
      // Reconstruct the length-prefixed header. A record whose interior role is
      // identified ([_c4RetainsInterior]) retains its payload byte-faithfully
      // (the string / path / help-text / string-table / cluster content); an
      // unidentified payload (unknown opcode, odd-shaped rectangle) stays copied.
      final out = Uint8List(headerLen);
      out[0] = kHeapRecordPrefix;
      out[1] = rec.opcode;
      if (headerLen == 5) {
        out[2] = 0xff;
        _putU16(out, 3, rec.payload.length);
      } else {
        out[2] = rec.payload.length;
      }
      final retained = _c4RetainsInterior(rec.kind.shape) ? rec.payload.length : 0;
      return _Modeled(out, headerLen, expected: true, retained: retained);
    }
    return _nothing;
  }

  // Attribute records `<op> <id> <value>`.
  final attr = decodeHeapAttr(body, offset);
  if (attr != null) {
    switch (attr.width) {
      case HeapAttrWidth.flag:
        return _Modeled(Uint8List.fromList([body[offset], body[offset + 1]]), 2, expected: true);
      case HeapAttrWidth.u8:
      case HeapAttrWidth.u16:
      case HeapAttrWidth.u24:
      case HeapAttrWidth.rgb:
        final value = attr.value;
        if (value is! int) return _nothing;
        final valueBytes = attr.length - 2;
        final out = Uint8List(attr.length);
        out[0] = body[offset];
        out[1] = body[offset + 1];
        for (var i = 0; i < valueBytes; i++) {
          out[2 + i] = (value >> (8 * (valueBytes - 1 - i))) & 0xff;
        }
        return _Modeled(out, attr.length, expected: true);
      case HeapAttrWidth.rect:
        final rect = attr.value;
        if (rect is! HeapRect) return _nothing;
        final out = Uint8List(11);
        out[0] = body[offset];
        out[1] = body[offset + 1];
        out[2] = 0x08;
        _putS16(out, 3, rect.top);
        _putS16(out, 5, rect.left);
        _putS16(out, 7, rect.bottom);
        _putS16(out, 9, rect.right);
        return _Modeled(out, 11, expected: true);
      case HeapAttrWidth.f64:
        // The `Cx <id> 08` header is reconstructed; the 8-byte f64 payload is
        // retained byte-faithfully ([HeapAttr.rawValueBytes]) — a re-encode of the
        // double is not guaranteed bit-identical, but the stored bytes are exact.
        return _Modeled(
          Uint8List.fromList([body[offset], body[offset + 1], 0x08]),
          3,
          expected: true,
          retained: 8,
        );
      case HeapAttrWidth.blob:
      case HeapAttrWidth.container:
        // The length-prefixed header is reconstructed; the payload interior is
        // retained byte-faithfully ([HeapAttr.rawValueBytes]) — a printable-
        // filtered blob string / opaque container, exact by retention.
        if (body[offset] == 0xc6 && offset + 2 < body.length && body[offset + 2] == 0xff) {
          final len = attr.length - 5;
          final out = Uint8List(5);
          out[0] = body[offset];
          out[1] = body[offset + 1];
          out[2] = 0xff;
          _putU16(out, 3, len);
          return _Modeled(out, 5, expected: true, retained: len);
        }
        return _Modeled(
          Uint8List.fromList([body[offset], body[offset + 1], attr.length - 3]),
          3,
          expected: true,
          retained: attr.length - 3,
        );
    }
  }

  // Typed-list property / group-open records `<op> <subop> <count> <tag> …` on
  // the group-open leads: the 3-byte `<op> <subop> <count>` framing is
  // reconstructed and the typed-item region (whose per-item stride is understood
  // by the walk's `_typedList` framing) is retained byte-faithfully. A 2-byte
  // bare selector is modeled whole.
  if (kHeapGroupOpenLeads.contains(lead)) {
    if (spanLength >= 4 && isHeapTypeTag(body[offset + 3])) {
      return _Modeled(
        Uint8List.fromList([body[offset], body[offset + 1], body[offset + 2]]),
        3,
        expected: true,
        retained: spanLength - 3,
      );
    }
    if (spanLength == 2) {
      return _Modeled(Uint8List.fromList([body[offset], body[offset + 1]]), 2, expected: true);
    }
  }

  return _nothing;
}

/// The model/copied byte split of an inflated heap body, without materializing
/// the re-emitted bytes. Produced by [attributeHeapBody]; the field meanings
/// match [HeapWriteResult].
class HeapContentSplit {
  const HeapContentSplit({required this.modelBytes, required this.copiedBytes, required this.modelBugs});

  final int modelBytes;
  final int copiedBytes;
  final int modelBugs;
}

/// Attributes an inflated heap [body] into model vs copied bytes **without**
/// allocating the re-emitted buffer — the lean path for the corpus scoreboard
/// sweep. Each modeled record is still reconstructed and verified against the
/// original bytes (so [modelBytes] is honest); only the output concatenation is
/// skipped. Total/bounds-safe. [serializeHeapBody] materializes the bytes on top
/// of the same walk.
///
/// [sectionTag] selects the grammar: `VCTP` is a type-pool (a length-prefixed
/// type-descriptor list + a top-level index list — see [typePoolFrames]); every
/// other tag (and null) is walked as an object-record heap ([walkHeapBody]).
HeapContentSplit attributeHeapBody(Uint8List body, [String? sectionTag]) {
  if (sectionTag == 'VCTP') {
    return typePoolFrames(body)
        ? HeapContentSplit(modelBytes: body.length, copiedBytes: 0, modelBugs: 0)
        : HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (body.length < 4) {
    return HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  var model = 0;
  var copied = 4; // leading u32 content-length — framing, copied verbatim.
  var bugs = 0;
  final walk = walkHeapBody(body);
  for (final span in walk.spans) {
    final m = _modelRecord(body, span.offset, span.lead, span.length);
    final modelLen = _verifiedModelLength(body, span.offset, m);
    if (m.length > 0 && modelLen == 0 && m.expected) bugs++;
    model += modelLen;
    copied += span.length - modelLen;
  }
  final coveredEnd = 4 + walk.coveredBytes;
  if (coveredEnd < body.length) copied += body.length - coveredEnd;
  return HeapContentSplit(modelBytes: model, copiedBytes: copied, modelBugs: bugs);
}

/// The modeled length of [m] once its header is verified against the original
/// bytes at [offset]: the reconstructed header ([m].length) plus its byte-faithful
/// retained interior ([m].retained) when the header reproduces the original bytes
/// exactly, else 0 (the record is then copied verbatim, preserving byte-exactness).
/// The retained interior needs no comparison — it is the record's own content
/// bytes, retained verbatim from the model.
int _verifiedModelLength(Uint8List body, int offset, _Modeled m) {
  final prefix = m.prefix;
  if (prefix == null || m.length == 0) return 0;
  for (var i = 0; i < m.length; i++) {
    if (prefix[i] != body[offset + i]) return 0;
  }
  return m.length + m.retained;
}

/// Re-serializes an inflated heap [body] from its decoded model, returning the
/// byte-identical re-emission and the model/copied byte split. Total/bounds-safe
/// (never throws). See the library doc for the model-sourced record families.
/// [attributeHeapBody] returns the same split without building [HeapWriteResult.bytes].
///
/// [sectionTag] selects the grammar: `VCTP` re-serializes as a type pool
/// ([reserializeTypePool]) — its structural words are reconstructed and its
/// descriptor interiors retained byte-faithfully, so the whole body is
/// model-sourced when it frames; every other tag (and null) is re-emitted as an
/// object-record heap.
HeapWriteResult serializeHeapBody(Uint8List body, [String? sectionTag]) {
  if (sectionTag == 'VCTP') {
    final reserialized = reserializeTypePool(body);
    if (reserialized != null) {
      return HeapWriteResult(bytes: reserialized, modelBytes: body.length, copiedBytes: 0, modelBugs: 0);
    }
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }

  final out = BytesBuilder(copy: false);
  var model = 0;
  var copied = 0;
  var bugs = 0;

  if (body.length < 4) {
    out.add(body);
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }

  // Leading `u32` content-length — framing, copied verbatim.
  out.add(Uint8List.sublistView(body, 0, 4));
  copied += 4;

  final walk = walkHeapBody(body);
  for (final span in walk.spans) {
    final offset = span.offset;
    final m = _modelRecord(body, offset, span.lead, span.length);
    final modelLen = _verifiedModelLength(body, offset, m);
    if (m.length > 0 && modelLen == 0 && m.expected) bugs++;

    if (modelLen > 0) {
      out.add(m.prefix!); // reconstructed header (m.length bytes)
      if (m.retained > 0) {
        // Byte-faithful retained interior: the record's own content bytes.
        out.add(Uint8List.sublistView(body, offset + m.length, offset + m.length + m.retained));
      }
      model += modelLen;
    }
    final rest = span.length - modelLen;
    if (rest > 0) {
      out.add(Uint8List.sublistView(body, offset + modelLen, offset + span.length));
      copied += rest;
    }
  }

  // Any tail the walk did not frame (a stop point or trailing padding).
  final coveredEnd = 4 + walk.coveredBytes;
  if (coveredEnd < body.length) {
    out.add(Uint8List.sublistView(body, coveredEnd));
    copied += body.length - coveredEnd;
  }

  return HeapWriteResult(bytes: out.toBytes(), modelBytes: model, copiedBytes: copied, modelBugs: bugs);
}
