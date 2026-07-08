import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../labwright_rsrc_parse.dart';

/// A block section after decompression. Heap sections in a VI are stored as
/// `[u32 decompressedSize][zlib stream]`; this inflates them. Uncompressed
/// sections pass through unchanged.
class DecodedSection {
  DecodedSection({required this.section, required this.bytes, required this.wasCompressed});

  final ViSection section;

  /// The section's logical bytes: decompressed if it was a zlib heap, else raw.
  final Uint8List bytes;

  final bool wasCompressed;

  String get tag => section.tag;

  int get index => section.index;

  int get length => bytes.length;
}

/// A heap section begins with a 4-byte big-endian decompressed size followed by
/// a zlib stream (CMF byte `0x78`). This is a cheap pre-check before inflating.
bool _looksCompressed(Uint8List bytes) => bytes.length >= 6 && bytes[4] == 0x78;

/// Upper bound on a heap section's declared decompressed size. Real VIs stay far
/// below this — the entire corpus tops out under 16 MiB — so a larger declared
/// size signals a corrupt or hostile stream (a zlib "decompression bomb": a few
/// KB inflating to gigabytes). We decline to inflate past this and fall back to
/// raw, keeping decode total — an OOM would otherwise crash the (synchronous,
/// UI-isolate) load path with no `ViFormatException`. 64 MiB sits in the clean
/// gap above every real section and below the implausible (~GiB) declarations.
const int _maxDecompressed = 64 * 1024 * 1024;

/// Whether [payload] is a stored heap payload (`[u32 size][zlib stream]`) — the
/// cheap CMF-byte pre-check ([_looksCompressed]). Public so the writer/scoreboard
/// share the single compressed-payload predicate with the decoder.
bool isCompressedHeapPayload(Uint8List payload) => _looksCompressed(payload);

/// Inflates a stored heap payload `[u32 declaredSize][zlib stream]` to its
/// decompressed content, or returns null when [payload] is not a heap payload,
/// declares an implausible size (> [_maxDecompressed], a decompression-bomb
/// guard), is not a valid zlib stream, or inflates to a size other than the
/// declared one. The returned bytes are the section's logical content (a heap
/// begins with its own leading `u32` content-length; see [walkHeapBody]).
/// Never throws.
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

/// Inflates a single [ViSection] if it is a `[u32 size][zlib]` heap; otherwise
/// returns it unchanged. Never throws: a malformed/!-matching stream (inflate
/// error or size mismatch) falls back to the raw bytes, so callers always get a
/// usable [DecodedSection].
DecodedSection inflateSection(ViSection section) {
  final bytes = section.bytes;
  final out = inflateHeapPayload(bytes);
  return out == null
      ? DecodedSection(section: section, bytes: bytes, wasCompressed: false)
      : DecodedSection(section: section, bytes: out, wasCompressed: true);
}

/// Reads every block section from a `.vi` and inflates the compressed ones.
/// Container-level corruption throws [ViFormatException] (from [readViSections]);
/// individual section decode is total.
List<DecodedSection> decodeSections(Uint8List viBytes) => [
  for (final section in readViSections(viBytes)) inflateSection(section),
];
