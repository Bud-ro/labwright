library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'container.dart';
import 'decode.dart';

Uint8List deflateHeapPayload(Uint8List inflated) {
  final z = const ZLibEncoder().encodeBytes(inflated);
  final out = Uint8List(4 + z.length);
  ByteData.sublistView(out).setUint32(0, inflated.length);
  out.setRange(4, out.length, z);
  return out;
}

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

bool viContentExact(Uint8List a, Uint8List b) => _bytesEqual(contentNormalizeVi(a), contentNormalizeVi(b));

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
