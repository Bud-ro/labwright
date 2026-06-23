import 'dart:typed_data';

/// Thrown when bytes are not a valid LabVIEW RSRC (`.vi`) container. The parser
/// bounds-checks every read, so it raises this rather than `RangeError`.
class ViFormatException implements Exception {
  ViFormatException(this.message);
  final String message;
  @override
  String toString() => 'ViFormatException: $message';
}

/// A structural summary of a LabVIEW VI — enough to say *what it is and does*
/// without (yet) recovering the block-diagram logic.
class ViSummary {
  ViSummary({
    required this.fileType,
    required this.creator,
    required this.formatVersion,
    required this.blocks,
    this.name,
  });

  /// e.g. `LVIN` (a VI), `LVCC` (a control/typedef).
  final String fileType;

  /// e.g. `LBVW` (LabVIEW).
  final String creator;

  /// RSRC container format version.
  final int formatVersion;

  /// The 4-char resource-block tags present (the VI's component inventory).
  final List<String> blocks;

  /// Best-effort VI name (trailing length-prefixed string), if recoverable.
  final String? name;

  bool get isVi => fileType == 'LVIN';
  bool get isControl => fileType == 'LVCC';

  /// Has executable logic (a block diagram).
  bool get hasBlockDiagram => blocks.contains('BDHb') || blocks.contains('BDHP');

  /// Has a front-panel UI.
  bool get hasFrontPanel => blocks.contains('FPHb') || blocks.contains('FPHP');

  /// Has a connector pane (its input/output signature).
  bool get hasConnectorPane => blocks.contains('CONP');

  /// References other VIs (calls sub-VIs).
  bool get hasSubViLinks => blocks.contains('LIvi') || blocks.contains('LIbd') || blocks.contains('LIfp');

  Map<String, Object?> toJson() => {
        'fileType': fileType,
        'creator': creator,
        'formatVersion': formatVersion,
        'name': name,
        'blocks': blocks,
        'hasBlockDiagram': hasBlockDiagram,
        'hasFrontPanel': hasFrontPanel,
        'hasConnectorPane': hasConnectorPane,
        'hasSubViLinks': hasSubViLinks,
      };

  /// A one-line human description of what the VI is/does.
  String describe() {
    final kind = switch (fileType) {
      'LVIN' => 'VI',
      'LVCC' => 'control/typedef',
      _ => fileType,
    };
    final caps = [
      if (hasFrontPanel) 'front panel',
      if (hasBlockDiagram) 'block diagram (logic)',
      if (hasConnectorPane) 'connector pane',
      if (hasSubViLinks) 'sub-VI links',
    ];
    return '${name ?? '(unnamed)'} — $kind, ${blocks.length} resource blocks'
        '${caps.isEmpty ? '' : '; has ${caps.join(', ')}'}';
  }
}

const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a]; // "RSRC\r\n"

/// Parses a LabVIEW RSRC container (`.vi`) into a [ViSummary]. Big-endian.
ViSummary parseVi(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);

  int u16(int p) {
    if (p < 0 || p + 2 > bytes.length) throw ViFormatException('truncated u16 at $p');
    return d.getUint16(p);
  }

  int u32(int p) {
    if (p < 0 || p + 4 > bytes.length) throw ViFormatException('truncated u32 at $p');
    return d.getUint32(p);
  }

  String tag(int p) {
    if (p < 0 || p + 4 > bytes.length) throw ViFormatException('truncated tag at $p');
    return String.fromCharCodes(bytes.sublist(p, p + 4));
  }

  if (bytes.length < 32) throw ViFormatException('too small to be an RSRC file');
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[i] != _magic[i]) throw ViFormatException('not an RSRC/.vi file (bad magic)');
  }

  final formatVersion = u16(6);
  final fileType = tag(8);
  final creator = tag(12);
  final infoOffset = u32(16);
  if (infoOffset < 0 || infoOffset + 0x30 > bytes.length) {
    throw ViFormatException('info section offset $infoOffset out of range');
  }

  // The info section repeats the 32-byte header, then a small sub-header whose
  // 4th word is the offset (within the info section) to the block-info list:
  // a u32 count followed by `count` entries of {4-char tag, u32, u32}.
  final blockListRel = u32(infoOffset + 0x2c);
  final countPos = infoOffset + blockListRel;
  final count = u32(countPos);
  if (count < 0 || count > 100000) throw ViFormatException('implausible block count $count');

  final blocks = <String>[];
  final seen = <String>{};
  var entry = countPos + 4;
  // Read `count` entries; tolerate an off-by-one convention by continuing while
  // the next tag is still printable, and stop at the first non-tag.
  for (var i = 0; i < count + 2 && entry + 12 <= bytes.length; i++) {
    final t = tag(entry);
    if (!_printableTag(t)) break;
    if (seen.add(t)) blocks.add(t);
    entry += 12;
  }

  return ViSummary(
    fileType: fileType,
    creator: creator,
    formatVersion: formatVersion,
    blocks: blocks,
    name: _trailingName(bytes),
  );
}

bool _printableTag(String s) {
  if (s.length != 4) return false;
  for (final c in s.codeUnits) {
    if (c < 0x20 || c >= 0x7f) return false;
  }
  return true;
}

/// Recovers the trailing length-prefixed VI name (a Pascal string at EOF), if
/// present. Scans largest-first so the full name wins over shorter coincidences.
String? _trailingName(Uint8List b) {
  final maxLen = b.length - 1 < 255 ? b.length - 1 : 255;
  for (var len = maxLen; len >= 1; len--) {
    final lenPos = b.length - 1 - len;
    if (lenPos < 0) continue;
    if (b[lenPos] != len) continue;
    var ok = true;
    for (var i = lenPos + 1; i < b.length; i++) {
      if (b[i] < 0x20 || b[i] >= 0x7f) {
        ok = false;
        break;
      }
    }
    if (ok) return String.fromCharCodes(b.sublist(lenPos + 1));
  }
  return null;
}
