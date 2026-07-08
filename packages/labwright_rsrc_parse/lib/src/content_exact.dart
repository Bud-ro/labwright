/// **Content-exact** correctness for the `.vi` writer.
///
/// A VI's heap sections are stored zlib-deflated; LabVIEW/TestStand read them
/// THROUGH zlib. So correctness for a rewritten container is defined not at the
/// stored-bytes level but at the **inflated-content** level: a rewritten `.vi`
/// is *content-exact* with the original iff every section matches — an
/// uncompressed section byte-for-byte, a compressed section
/// inflated-content-for-inflated-content. A compressed section re-emitted as a
/// standard RFC-1950 zlib stream ([deflateHeapPayload]) carrying the same
/// inflated content is content-exact even though its stored bytes differ from
/// NI's deflate output.
///
/// Correctness is defined and checked here at the inflated-content level only.
/// This is a clean-room project with no LabVIEW to load, so acceptance of a
/// re-deflated stream by LabVIEW is not empirically proven; what IS proven is
/// that a Dart [ZLibEncoder] stream round-trips the content
/// ([reDeflatePreservesContent]) and that the container stays valid and
/// content-exact after the swap.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'container.dart';
import 'decode.dart';

/// Deflates [inflated] to a stored heap payload `[u32 inflatedLength][zlib]`
/// using a standard RFC-1950 zlib stream (Dart's [ZLibEncoder]). The result
/// inflates back to [inflated] byte-for-byte ([inflateHeapPayload]), so it is a
/// LabVIEW-compatible container for the same content — its stored length differs
/// from NI's deflate, which the writer's offset math absorbs.
Uint8List deflateHeapPayload(Uint8List inflated) {
  final z = const ZLibEncoder().encodeBytes(inflated);
  final out = Uint8List(4 + z.length);
  ByteData.sublistView(out).setUint32(0, inflated.length);
  out.setRange(4, out.length, z);
  return out;
}

/// Whether re-deflating [payload]'s inflated content with a standard zlib stream
/// preserves it: `inflate(deflate(inflate(payload))) == inflate(payload)`,
/// byte-for-byte. Returns null if [payload] is not a compressed heap payload
/// (nothing to prove). This is the "compatible zlib" evidence gatherable without
/// LabVIEW: the content survives a Dart-zlib round-trip.
bool? reDeflatePreservesContent(Uint8List payload) {
  final inflated = inflateHeapPayload(payload);
  if (inflated == null) return null;
  final round = inflateHeapPayload(deflateHeapPayload(inflated));
  if (round == null || round.length != inflated.length) return false;
  for (var i = 0; i < inflated.length; i++) {
    if (round[i] != inflated[i]) return false;
  }
  return true;
}

/// The **content-normalized** image of [viBytes]: the container re-serialized
/// with every compressed section payload replaced by its inflated content. Two
/// VIs are content-exact iff their normalized images are equal ([viContentExact])
/// — so a section re-deflated to different stored bytes but the same inflated
/// content normalizes identically. Uncompressed sections, the header, the info
/// area, and padding gaps pass through unchanged, so their equality is required
/// too. Throws [ViFormatException] on a non-RSRC container.
///
/// Note: a compressed heap nested inside a `VINS` embedded sub-VI is not
/// recursively normalized here — the sub-VI payload is compared as stored bytes.
Uint8List contentNormalizeVi(Uint8List viBytes) {
  final vi = ViVi.parse(viBytes);
  final segs = [
    for (final seg in vi.dataSegments)
      if (seg is ViSectionData) _normalizeSection(seg) else seg,
  ];
  return ViVi(header: vi.header, dataSegments: segs, infoArea: vi.infoArea).serialize();
}

ViDataSegment _normalizeSection(ViSectionData seg) {
  final inflated = inflateHeapPayload(seg.payload);
  return inflated == null ? seg : ViSectionData(secRel: seg.secRel, payload: inflated);
}

/// Whether [a] and [b] are content-exact — every section matches at the
/// inflated-content level (see the library doc). Both must be RSRC containers.
bool viContentExact(Uint8List a, Uint8List b) => _bytesEqual(contentNormalizeVi(a), contentNormalizeVi(b));

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
