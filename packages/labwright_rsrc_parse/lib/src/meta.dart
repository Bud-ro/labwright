import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// The version string and title read from `vers`.
class ViVersionInfo {
  const ViVersionInfo({this.version, this.title});

  final String? version;

  final String? title;
}

final RegExp _versionPattern = RegExp(r'^\d{1,2}\.\d');

/// Reads the first `vers` string that looks like a version and the title that follows a
/// `VIDS` marker.
ViVersionInfo decodeVersion(Uint8List viBytes) => versionFromSections(readViSections(viBytes));

ViVersionInfo versionFromSections(Iterable<ViSection> sections) {
  String? version, title;
  for (final section in sections) {
    if (section.tag != 'vers') continue;
    for (final str in _pascalStrings(section.bytes)) {
      if (version == null && _versionPattern.hasMatch(str)) version = str;
    }
    title ??= _vidsTitle(section.bytes);
  }
  return ViVersionInfo(version: version, title: title);
}

/// Per-tag totals over a file's sections: how many, their raw and inflated byte sizes, and
/// whether any was compressed.
class BlockComponent {
  const BlockComponent({
    required this.tag,
    required this.sectionCount,
    required this.rawBytes,
    required this.decompressedBytes,
    required this.compressed,
  });

  final String tag;

  final int sectionCount;

  final int rawBytes;

  final int decompressedBytes;

  final bool compressed;
}

/// The per-tag totals of a VI, largest inflated size first.
List<BlockComponent> blockComponents(Uint8List viBytes) => componentsFromDecoded(decodeSections(viBytes));

List<BlockComponent> componentsFromDecoded(Iterable<DecodedSection> decoded) {
  final byTag = <String, List<DecodedSection>>{};
  for (final decodedSection in decoded) {
    (byTag[decodedSection.tag] ??= <DecodedSection>[]).add(decodedSection);
  }
  final out = [
    for (final entry in byTag.entries)
      BlockComponent(
        tag: entry.key,
        sectionCount: entry.value.length,
        rawBytes: entry.value.fold<int>(0, (a, d) => a + d.section.bytes.length),
        decompressedBytes: entry.value.fold<int>(0, (a, d) => a + d.bytes.length),
        compressed: entry.value.any((d) => d.wasCompressed),
      ),
  ];
  out.sort((a, b) => b.decompressedBytes.compareTo(a.decompressedBytes));
  return out;
}

String _pascalChars(Uint8List bytes, int start, int len) => String.fromCharCodes(bytes.sublist(start, start + len));

bool _allPrintable(Uint8List bytes, int start, int len) {
  for (var j = start; j < start + len; j++) {
    if (bytes[j] < 32 || bytes[j] >= 127) return false;
  }
  return true;
}

List<String> _pascalStrings(Uint8List bytes) {
  final out = <String>[];
  var i = 0;
  while (i < bytes.length) {
    final len = bytes[i];
    if (len >= 1 && len <= 120 && i + 1 + len <= bytes.length && _allPrintable(bytes, i + 1, len)) {
      out.add(_pascalChars(bytes, i + 1, len));
      i += 1 + len;
      continue;
    }
    i++;
  }
  return out;
}

/// Text stored in `CPC2` as a length-prefixed printable run, or null when it holds none.
bool _isTextByte(int byte) => byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127);

String? cpc2Description(Iterable<ViSection> sections) {
  for (final section in sections) {
    if (section.tag != 'CPC2') continue;
    final bytes = section.bytes;
    if (bytes.length < 5) continue;
    final len = ByteData.sublistView(bytes).getUint32(0);
    if (len == 0 || 4 + len > bytes.length) continue;
    final ok = bytes.getRange(4, 4 + len).every(_isTextByte);
    if (ok) return String.fromCharCodes(bytes.sublist(4, 4 + len));
  }
  return null;
}

String? _vidsTitle(Uint8List bytes) {
  for (var i = 0; i + 5 <= bytes.length; i++) {
    if (bytes[i] == 0x56 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x44 && bytes[i + 3] == 0x53) {
      final len = bytes[i + 4];
      if (len > 0 && i + 5 + len <= bytes.length && _allPrintable(bytes, i + 5, len)) {
        return _pascalChars(bytes, i + 5, len);
      }
    }
  }
  return null;
}
