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
