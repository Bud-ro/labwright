import 'dart:typed_data';

import 'package:labwright_viparse/labwright_viparse.dart';

import 'decode.dart';

/// The LabVIEW version a VI was saved in, plus its embedded title/description.
class ViVersionInfo {
  const ViVersionInfo({this.version, this.title});

  /// The LabVIEW version string from the `vers` block, e.g. `10.0` (null if not
  /// recoverable).
  final String? version;

  /// The VI's embedded title/description (from the `vers` block's `VIDS`
  /// record), if present.
  final String? title;
}

final RegExp _versionPattern = RegExp(r'^\d{1,2}\.\d');

/// Decodes the LabVIEW version + title from a `.vi`'s `vers` block. Reliable:
/// every VI in the validation corpus yields both.
ViVersionInfo decodeVersion(Uint8List viBytes) => versionFromSections(readViSections(viBytes));

/// [decodeVersion] over already-read sections (the `vers` block is uncompressed,
/// so raw [ViSection] bytes suffice). Total — never throws.
ViVersionInfo versionFromSections(Iterable<ViSection> sections) {
  String? version;
  String? title;
  for (final s in sections) {
    if (s.tag != 'vers') continue;
    for (final str in _pascalStrings(s.bytes)) {
      if (version == null && _versionPattern.hasMatch(str)) version = str;
    }
    title ??= _vidsTitle(s.bytes);
  }
  return ViVersionInfo(version: version, title: title);
}

/// A VI block summarized by size — its component footprint. Reliable (just
/// section sizes), regardless of whether the heap's logic can be parsed.
class BlockComponent {
  const BlockComponent({
    required this.tag,
    required this.sectionCount,
    required this.rawBytes,
    required this.decompressedBytes,
    required this.compressed,
  });

  /// The 4-char block tag (e.g. `BDEx`, `FPHb`, `DTHP`).
  final String tag;

  /// Number of sections in this block.
  final int sectionCount;

  /// Total stored (possibly compressed) bytes across the block's sections.
  final int rawBytes;

  /// Total bytes after inflation (== [rawBytes] for uncompressed blocks).
  final int decompressedBytes;

  /// Whether any section in the block was zlib-compressed.
  final bool compressed;
}

/// Per-block size summary for a VI (largest decompressed first) — the VI's
/// "components" view (how heavy the block diagram / front panel / type data are).
/// Reliable and total.
List<BlockComponent> blockComponents(Uint8List viBytes) => componentsFromDecoded(decodeSections(viBytes));

/// [blockComponents] over already-decoded sections.
List<BlockComponent> componentsFromDecoded(Iterable<DecodedSection> decoded) {
  final byTag = <String, List<DecodedSection>>{};
  for (final d in decoded) {
    (byTag[d.tag] ??= <DecodedSection>[]).add(d);
  }
  final out = <BlockComponent>[];
  byTag.forEach((tag, list) {
    var raw = 0;
    var dec = 0;
    var comp = false;
    for (final d in list) {
      raw += d.section.bytes.length;
      dec += d.bytes.length;
      if (d.wasCompressed) comp = true;
    }
    out.add(BlockComponent(tag: tag, sectionCount: list.length, rawBytes: raw, decompressedBytes: dec, compressed: comp));
  });
  out.sort((a, b) => b.decompressedBytes.compareTo(a.decompressedBytes));
  return out;
}

/// Best-effort human-readable strings embedded in a VI's heaps (control labels,
/// help/tooltip text, value lists). **Heuristic**, not authoritative: the heap
/// is an opcode-serialized object tree, so this scans for length-prefixed
/// printable runs and may include occasional fragments. Useful for "what does
/// this VI contain"; deduplicated, order-preserving.
List<String> extractHeapStrings(Uint8List viBytes, {int minLength = 4}) =>
    heapStringsFromDecoded(decodeSections(viBytes), minLength: minLength);

/// [extractHeapStrings] over already-decoded sections.
List<String> heapStringsFromDecoded(Iterable<DecodedSection> decoded, {int minLength = 4}) {
  final seen = <String>{};
  final out = <String>[];
  for (final d in decoded) {
    for (final s in _pascalStrings(d.bytes, minLength: minLength)) {
      if (_looksWordy(s) && seen.add(s)) out.add(s);
    }
  }
  return out;
}

/// Extracts `[u8 len][len printable bytes]` runs from [h]. Total.
List<String> _pascalStrings(Uint8List h, {int minLength = 1, int maxLength = 120}) {
  final out = <String>[];
  var i = 0;
  while (i < h.length) {
    final len = h[i];
    if (len >= minLength && len <= maxLength && i + 1 + len <= h.length) {
      var printable = true;
      for (var j = i + 1; j < i + 1 + len; j++) {
        if (h[j] < 32 || h[j] >= 127) {
          printable = false;
          break;
        }
      }
      if (printable) {
        out.add(String.fromCharCodes(h.sublist(i + 1, i + 1 + len)));
        i += 1 + len;
        continue;
      }
    }
    i++;
  }
  return out;
}

/// True if [s] contains at least one ASCII letter (filters numeric/byte noise).
bool _looksWordy(String s) {
  for (final c in s.codeUnits) {
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) return true;
  }
  return false;
}

/// Reads the `VIDS` record's title (`'VIDS'` then `[u8 len][string]`) from a
/// `vers` section, or null.
String? _vidsTitle(Uint8List b) {
  for (var i = 0; i + 5 <= b.length; i++) {
    if (b[i] == 0x56 && b[i + 1] == 0x49 && b[i + 2] == 0x44 && b[i + 3] == 0x53) {
      final len = b[i + 4];
      if (i + 5 + len <= b.length) {
        var printable = true;
        for (var j = i + 5; j < i + 5 + len; j++) {
          if (b[j] < 32 || b[j] >= 127) {
            printable = false;
            break;
          }
        }
        if (printable && len > 0) return String.fromCharCodes(b.sublist(i + 5, i + 5 + len));
      }
    }
  }
  return null;
}
