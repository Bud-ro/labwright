import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

/// A block section after decompression. Heap sections in a VI are stored as
/// `[u32 decompressedSize][zlib stream]`; this inflates them. Uncompressed
/// sections pass through unchanged.
class DecodedSection {
  DecodedSection({required this.section, required this.bytes, required this.wasCompressed});

  /// The source section (tag, index, raw bytes).
  final ViSection section;

  /// The section's logical bytes: decompressed if it was a zlib heap, else raw.
  final Uint8List bytes;

  /// Whether [bytes] came from inflating a zlib stream.
  final bool wasCompressed;

  /// The owning block's 4-char tag (e.g. `BDEx`, `DTHP`).
  String get tag => section.tag;

  /// The section's index within its block.
  int get index => section.index;

  /// Decompressed length in bytes.
  int get length => bytes.length;
}

/// A heap section begins with a 4-byte big-endian decompressed size followed by
/// a zlib stream (CMF byte `0x78`). This is a cheap pre-check before inflating.
bool _looksCompressed(Uint8List b) => b.length >= 6 && b[4] == 0x78;

/// Inflates a single [ViSection] if it is a `[u32 size][zlib]` heap; otherwise
/// returns it unchanged. Never throws: a malformed/!-matching stream (inflate
/// error or size mismatch) falls back to the raw bytes, so callers always get a
/// usable [DecodedSection].
DecodedSection inflateSection(ViSection s) {
  final b = s.bytes;
  if (_looksCompressed(b)) {
    final declared = ByteData.sublistView(b).getUint32(0);
    try {
      final out = const ZLibDecoder().decodeBytes(b.sublist(4));
      if (out.length == declared) {
        return DecodedSection(section: s, bytes: out, wasCompressed: true);
      }
    } catch (_) {
      // not actually a valid zlib stream — fall through to raw
    }
  }
  return DecodedSection(section: s, bytes: b, wasCompressed: false);
}

/// Reads every block section from a `.vi` and inflates the compressed ones.
/// Container-level corruption throws [ViFormatException] (from [readViSections]);
/// individual section decode is total.
List<DecodedSection> decodeSections(Uint8List viBytes) =>
    [for (final s in readViSections(viBytes)) inflateSection(s)];
