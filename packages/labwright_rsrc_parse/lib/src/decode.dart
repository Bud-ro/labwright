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
bool _looksCompressed(Uint8List b) => b.length >= 6 && b[4] == 0x78;

/// Upper bound on a heap section's declared decompressed size. Real VIs stay far
/// below this — the entire corpus tops out under 16 MiB — so a larger declared
/// size signals a corrupt or hostile stream (a zlib "decompression bomb": a few
/// KB inflating to gigabytes). We decline to inflate past this and fall back to
/// raw, keeping decode total — an OOM would otherwise crash the (synchronous,
/// UI-isolate) load path with no `ViFormatException`. 64 MiB sits in the clean
/// gap above every real section and below the implausible (~GiB) declarations.
const int _maxDecompressed = 64 * 1024 * 1024;

/// Inflates a single [ViSection] if it is a `[u32 size][zlib]` heap; otherwise
/// returns it unchanged. Never throws: a malformed/!-matching stream (inflate
/// error or size mismatch) falls back to the raw bytes, so callers always get a
/// usable [DecodedSection].
DecodedSection inflateSection(ViSection s) {
  final b = s.bytes;
  final raw = DecodedSection(section: s, bytes: b, wasCompressed: false);
  if (!_looksCompressed(b)) return raw;
  final declared = ByteData.sublistView(b).getUint32(0);
  if (declared > _maxDecompressed) return raw;
  try {
    final out = const ZLibDecoder().decodeBytes(b.sublist(4));
    if (out.length == declared) {
      return DecodedSection(section: s, bytes: out, wasCompressed: true);
    }
  } catch (_) {
    // Not a valid zlib stream — fall through to the raw bytes.
  }
  return raw;
}

/// Reads every block section from a `.vi` and inflates the compressed ones.
/// Container-level corruption throws [ViFormatException] (from [readViSections]);
/// individual section decode is total.
List<DecodedSection> decodeSections(Uint8List viBytes) =>
    [for (final s in readViSections(viBytes)) inflateSection(s)];
