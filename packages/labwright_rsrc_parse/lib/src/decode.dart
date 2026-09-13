import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../labwright_rsrc_parse.dart';

/// A section with its payload inflated when it carried the compressed envelope.
class DecodedSection {
  DecodedSection({required this.section, required this.bytes, required this.wasCompressed});

  final ViSection section;

  final Uint8List bytes;

  final bool wasCompressed;

  String get tag => section.tag;

  int get index => section.index;

  int get length => bytes.length;
}

bool _looksCompressed(Uint8List bytes) => bytes.length >= 6 && bytes[4] == 0x78;

const int _maxDecompressed = 64 * 1024 * 1024;

/// Whether the payload has the compressed envelope: a `u32` inflated length followed by a
/// zlib stream.
bool isCompressedHeapPayload(Uint8List payload) => _looksCompressed(payload);

/// The inflated payload, or null when the envelope is absent, the declared length exceeds
/// 64 MiB, or the stream does not inflate to the declared length.
Uint8List? inflateHeapPayload(Uint8List payload) {
  if (!_looksCompressed(payload)) return null;
  final declared = ByteData.sublistView(payload).getUint32(0);
  if (declared > _maxDecompressed) return null;
  try {
    final out = const ZLibDecoder().decodeBytes(payload.sublist(4));
    return out.length == declared ? out : null;
  } catch (_) {
    return null;
  }
}

DecodedSection inflateSection(ViSection section) {
  final bytes = section.bytes;
  final out = inflateHeapPayload(bytes);
  return out == null
      ? DecodedSection(section: section, bytes: bytes, wasCompressed: false)
      : DecodedSection(section: section, bytes: out, wasCompressed: true);
}

/// The file's own sections, each inflated when compressed.
List<DecodedSection> decodeSections(Uint8List viBytes) => [
  for (final section in readViSections(viBytes)) inflateSection(section),
];
