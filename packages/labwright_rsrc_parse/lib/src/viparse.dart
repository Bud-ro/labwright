import 'dart:typed_data';

import 'block_tag.dart';
import 'container.dart' show SectionNamespace;
import 'pth0.dart';

/// Thrown when bytes do not hold an RSRC container this package can read.
class ViFormatException implements Exception {
  ViFormatException(this.message);
  final String message;
  @override
  String toString() => 'ViFormatException: $message';
}

/// The file-type 4CC at offset 8 of the header.
enum ViFileType {
  vi('LVIN'),

  control('LVCC')
  ;

  const ViFileType(this.fourCc);

  final String fourCc;

  static ViFileType? of(String fourCc) {
    for (final t in values) {
      if (t.fourCc == fourCc) return t;
    }
    return null;
  }
}

/// What a file is and which blocks it carries, read from the header and block list alone.
class ViSummary {
  ViSummary({
    required this.fileType,
    required this.creator,
    required this.formatVersion,
    required this.blocks,
    this.name,
  });

  final String fileType;

  final String creator;

  final int formatVersion;

  /// The block tags in block-list order.
  final List<String> blocks;

  /// The VI name from the info area's trailing Pascal string.
  final String? name;

  /// Null for a file type other than a VI or a control.
  ViFileType? get kind => ViFileType.of(fileType);

  bool get isVi => kind == ViFileType.vi;
  bool get isControl => kind == ViFileType.control;

  bool _has(BlockCategory category) => blocks.any((tag) => BlockTag.of(tag)?.category == category);

  bool get hasBlockDiagram => _has(BlockCategory.blockDiagramHeap);

  bool get hasFrontPanel => _has(BlockCategory.frontPanelHeap);

  bool get hasConnectorPane => blocks.contains('CONP');

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

  String describe() {
    final kind = switch (this.kind) {
      ViFileType.vi => 'VI',
      ViFileType.control => 'control/typedef',
      null => fileType,
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

/// One section of a block: its payload as a view into the file at [dataOffset] + 4.
class ViSection {
  ViSection({required this.tag, required this.index, required this.dataOffset, required this.bytes});

  final String tag;

  /// Position among the block's sections.
  final int index;

  /// The section's `secRel`: the offset of its length word within the data area.
  final int dataOffset;

  final Uint8List bytes;
}

const List<int> _magic = [0x52, 0x53, 0x52, 0x43, 0x0d, 0x0a];

bool _allPrintable(Uint8List bytes, int start, int end) {
  for (var i = start; i < end; i++) {
    if (bytes[i] < 0x20 || bytes[i] >= 0x7f) return false;
  }
  return true;
}

final _pathSep = RegExp(r'[\\/]');

String _baseName(String path) => path.split(_pathSep).last;

/// The embedded-namespace sections of a VI, or none when the file does not parse.
List<ViSection> embeddedSectionsOrEmpty(Uint8List bytes) {
  try {
    return readEmbeddedSections(bytes);
  } catch (_) {
    return const [];
  }
}

void _checkRsrcMagic(Uint8List bytes) {
  if (bytes.length < 32) throw ViFormatException('too small to be an RSRC file');
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[i] != _magic[i]) throw ViFormatException('not an RSRC/.vi file (bad magic)');
  }
}

({int countPos, int count}) _locateBlockList(int Function(int) u32, int infoOffset) {
  final countPos = infoOffset + u32(infoOffset + 0x2c);
  final count = u32(countPos);
  if (count > 100000) throw ViFormatException('implausible block count $count');
  return (countPos: countPos, count: count);
}

/// The file's own sections, in block-list order.
List<ViSection> readViSections(Uint8List bytes) => _readSections(bytes, SectionNamespace.own);

/// The sections of embedded resources (`LIBN`, `VINS`).
List<ViSection> readEmbeddedSections(Uint8List bytes) => _readSections(bytes, SectionNamespace.embedded);

List<ViSection> _readSections(Uint8List bytes, SectionNamespace namespace) {
  final view = ByteData.sublistView(bytes);

  int u32(int at) {
    if (at < 0 || at + 4 > bytes.length) throw ViFormatException('truncated u32 at $at');
    return view.getUint32(at);
  }

  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));

  _checkRsrcMagic(bytes);

  final infoOffset = u32(16);
  final dataOffset = u32(24);
  final dataSize = u32(28);
  if (infoOffset + 0x30 > bytes.length) throw ViFormatException('info section offset out of range');

  final (:countPos, :count) = _locateBlockList(u32, infoOffset);

  const descSize = 20;
  const finalDescSize = 12;
  final descBase = countPos + 8;
  final sections = <ViSection>[];
  var entry = countPos + 4;
  // The stored block count is one less than the number of entries.
  for (var i = 0; i <= count && entry + 12 <= bytes.length; i++) {
    final finalEntry = i == count;
    final tagText = tag(entry);
    final sectionCount = u32(entry + 4) + 1;
    final descRel = u32(entry + 8);
    entry += 12;
    if (!_printableTag(tagText)) continue;
    if (finalEntry && namespace != SectionNamespace.own) continue;
    for (var sectionIndex = 0; sectionIndex < sectionCount; sectionIndex++) {
      final dpos = descBase + descRel + sectionIndex * descSize;
      if (dpos + (finalEntry ? finalDescSize : descSize) > bytes.length) break;
      if (!finalEntry && view.getUint32(dpos + 16) != namespace.word) continue;
      final secRel = view.getUint32(dpos + 4);
      final pos = dataOffset + secRel;
      if (pos + 4 > bytes.length) continue;
      final len = view.getUint32(pos);
      if (len > dataSize || pos + 4 + len > bytes.length) continue;
      sections.add(
        ViSection(
          tag: tagText,
          index: sectionIndex,
          dataOffset: secRel,
          bytes: Uint8List.sublistView(bytes, pos + 4, pos + 4 + len),
        ),
      );
    }
  }
  return sections;
}

/// Reads the header and block list; throws [ViFormatException] when they are not an RSRC.
ViSummary parseVi(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);

  int u16(int at) {
    if (at + 2 > bytes.length) throw ViFormatException('truncated u16 at $at');
    return view.getUint16(at);
  }

  int u32(int at) {
    if (at < 0 || at + 4 > bytes.length) throw ViFormatException('truncated u32 at $at');
    return view.getUint32(at);
  }

  String tag(int at) {
    if (at + 4 > bytes.length) throw ViFormatException('truncated tag at $at');
    return String.fromCharCodes(bytes.sublist(at, at + 4));
  }

  _checkRsrcMagic(bytes);

  final formatVersion = u16(6);
  final fileType = tag(8);
  final creator = tag(12);
  final infoOffset = u32(16);
  if (infoOffset + 0x30 > bytes.length) {
    throw ViFormatException('info section offset $infoOffset out of range');
  }

  final (:countPos, :count) = _locateBlockList(u32, infoOffset);

  final blocks = <String>[];
  final seen = <String>{};
  var entry = countPos + 4;
  for (var i = 0; i <= count && entry + 12 <= bytes.length; i++) {
    final tagText = tag(entry);
    if (!_printableTag(tagText)) break;
    if (seen.add(tagText)) blocks.add(tagText);
    entry += 12;
  }

  return ViSummary(
    fileType: fileType,
    creator: creator,
    formatVersion: formatVersion,
    blocks: blocks,
    name: _viName(bytes, infoOffset),
  );
}

String? _viName(Uint8List bytes, int infoOffset) {
  if (infoOffset + 0x34 <= bytes.length) {
    final rel = ByteData.sublistView(bytes).getUint32(infoOffset + 0x30);
    final at = infoOffset + rel;
    if (at < bytes.length) {
      final len = bytes[at];
      if (len > 0 && at + 1 + len == bytes.length) return String.fromCharCodes(bytes.sublist(at + 1));
    }
  }
  return _trailingName(bytes);
}

bool _printableTag(String tag) => tag.length == 4 && tag.codeUnits.every((c) => c >= 0x20 && c < 0x7f);

List<String> readSubViNames(Uint8List bytes) {
  List<ViSection> secs;
  try {
    secs = readViSections(bytes);
  } catch (_) {
    return const [];
  }
  Uint8List? sectionBytes(String tag) {
    for (final section in secs) {
      if (section.tag == tag) return section.bytes;
    }
    return null;
  }

  final libd = sectionBytes('LIbd');
  if (libd == null || libd.isEmpty) return const [];

  final self = <String>{};
  final livi = sectionBytes('LIvi');
  if (livi != null) {
    final names = _pascalViNames(livi);
    if (names.isNotEmpty) self.add(_baseName(names.first).toLowerCase());
  }
  final trailing = _trailingName(bytes);
  if (trailing != null && trailing.toLowerCase().endsWith('.vi')) {
    self.add(_baseName(trailing).toLowerCase());
  }

  final seen = <String>{};
  final out = <String>[];
  for (final name in _pascalViNames(libd)) {
    final base = _baseName(name);
    final key = base.toLowerCase();
    if (self.contains(key)) continue;
    if (seen.add(key)) out.add(base);
  }
  return out;
}

enum ViSubViPathKind {
  relative,

  viLib,

  symbolic,

  other,
}

class ViSubViPath {
  const ViSubViPath({required this.kind, required this.components});

  final ViSubViPathKind kind;

  final List<String> components;

  String get fileName => components.isEmpty ? '' : components.last;

  int get upLevels {
    var empties = 0;
    while (empties < components.length && components[empties].isEmpty) {
      empties++;
    }
    return empties == 0 ? 0 : empties - 1;
  }

  List<String> get segments => [
    for (final component in components)
      if (component.isNotEmpty && !component.startsWith('<')) component,
  ];
}

List<ViSubViPath> readSubViPaths(Uint8List bytes) {
  List<ViSection> secs;
  try {
    secs = readViSections(bytes);
  } catch (_) {
    return const [];
  }
  Uint8List? libd;
  for (final section in secs) {
    if (section.tag == 'LIbd') {
      libd = section.bytes;
      break;
    }
  }
  if (libd == null || libd.isEmpty) return const [];

  final out = <ViSubViPath>[];
  final seen = <String>{};
  for (var i = 0; i + 12 <= libd.length; i++) {
    final extent = pth0ExtentAt(libd, i);
    if (extent == null) continue;
    final path = decodePth0(Uint8List.sublistView(libd, i, i + extent));
    if (path.componentCount == 0) continue;
    final components = path.components;
    final first = components.first;
    final kind = path.pathType == 1 && first.isEmpty
        ? ViSubViPathKind.relative
        : first == '<vilib>'
        ? ViSubViPathKind.viLib
        : first.startsWith('<') && first.endsWith('>')
        ? ViSubViPathKind.symbolic
        : ViSubViPathKind.other;
    final record = ViSubViPath(kind: kind, components: components);
    if (record.fileName.isEmpty) continue;
    if (seen.add(record.fileName.toLowerCase())) out.add(record);
  }
  return out;
}

List<String> _pascalViNames(Uint8List bytes) {
  final out = <String>[];
  for (var i = 0; i + 1 < bytes.length; i++) {
    final len = bytes[i];
    if (len < 4 || i + 1 + len > bytes.length) continue;
    if (!_allPrintable(bytes, i + 1, i + 1 + len)) continue;
    final text = String.fromCharCodes(bytes.sublist(i + 1, i + 1 + len));
    if (text.toLowerCase().endsWith('.vi')) {
      out.add(text);
      i += len;
    }
  }
  return out;
}

String? _trailingName(Uint8List bytes) {
  final maxLen = (bytes.length - 1).clamp(0, 255);
  for (var len = maxLen; len >= 1; len--) {
    final lenPos = bytes.length - 1 - len;
    if (bytes[lenPos] != len) continue;
    if (_allPrintable(bytes, lenPos + 1, bytes.length)) return String.fromCharCodes(bytes, lenPos + 1);
  }
  return null;
}
