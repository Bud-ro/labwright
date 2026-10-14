import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'vi_spec.dart';

/// The typed form of [section] decoded through its block's view, or null when the tag has
/// none or the payload does not fit the view; [version] is the saving version `vers` gives.
TypedSection? typedSectionOf(DecodedSection section, {ViVersionWord? version}) {
  final DecodedSection(:tag, :bytes, :index, wasCompressed: compressed) =
      section;
  final n = bytes.length;
  if (LegacyIconDepth.forTag(tag) case final depth?
      when n == depth.byteLength) {
    return IconSection.of(
      ViLegacyIcon(bytes, depth),
      index: index,
      compressed: compressed,
    );
  }
  return switch (BlockTag.of(tag)) {
    BlockTag.lvsr when ViSaveRecord.layout.fits(n) => SaveRecordSection.of(
      ViSaveRecord(bytes),
      index: index,
      compressed: compressed,
    ),
    BlockTag.vits => TagStoreSection.of(
      ViTagStore(bytes),
      index: index,
      compressed: compressed,
    ),
    BlockTag.bdpw when n == 32 || n == 48 => PasswordSection.of(
      ViPasswordRecord(bytes),
      index: index,
      compressed: compressed,
    ),
    BlockTag.rtsg ||
    BlockTag.obsg ||
    BlockTag.ccsg when ViSignature.layout.fits(n) => SignatureSection.of(
      tag,
      ViSignature(bytes),
      index: index,
      compressed: compressed,
    ),
    BlockTag.livi ||
    BlockTag.libd ||
    BlockTag.lifp ||
    BlockTag.lids when n >= _linkInfoMinSize => LinkInfoSection.of(
      tag,
      ViLinkInfo(bytes, version: version),
      index: index,
      compressed: compressed,
    ),
    _ => null,
  };
}

const _linkInfoMinSize = 12;

/// An icon (`icl8`, `icl4`, `ICON`) as its 32 pixel rows, top to bottom: per pixel `#` for
/// black and `.` for white at one bit, the palette index as one hex digit at four bits and as
/// two at eight.
final class IconSection extends TypedSection {
  IconSection({
    required this.depth,
    required this.rows,
    super.index,
    super.compressed,
  }) : super(depth.tag);

  factory IconSection.of(
    ViLegacyIcon icon, {
    int index = 0,
    bool compressed = false,
  }) => IconSection(
    depth: icon.depth,
    rows: [
      for (var y = 0; y < ViLegacyIcon.height; y++)
        [
          for (var x = 0; x < ViLegacyIcon.width; x++)
            _spellPixel(icon.depth, icon.pixelAt(x, y)),
        ].join(),
    ],
    index: index,
    compressed: compressed,
  );

  final LegacyIconDepth depth;

  final List<String> rows;

  @override
  Uint8List get payload => ViLegacyIcon.encode(depth, [
    for (final row in rows) ..._readPixels(depth, row),
  ]);

  @override
  String get constructor => 'IconSection';

  @override
  List<(String, Object?)> get arguments => [('depth', depth), ('rows', rows)];

  static String _spellPixel(LegacyIconDepth depth, int index) =>
      switch (depth) {
        LegacyIconDepth.mono => index == 0 ? '.' : '#',
        LegacyIconDepth.fourBit => index.toRadixString(16),
        LegacyIconDepth.eightBit => index.toRadixString(16).padLeft(2, '0'),
      };

  static Iterable<int> _readPixels(LegacyIconDepth depth, String row) sync* {
    switch (depth) {
      case LegacyIconDepth.mono:
        for (final unit in row.codeUnits) {
          yield unit == _black ? 1 : 0;
        }
      case LegacyIconDepth.fourBit:
        for (var i = 0; i < row.length; i++) {
          yield int.parse(row[i], radix: 16);
        }
      case LegacyIconDepth.eightBit:
        for (var i = 0; i < row.length; i += 2) {
          yield int.parse(row.substring(i, i + 2), radix: 16);
        }
    }
  }

  static final int _black = '#'.codeUnitAt(0);
}

/// A tag store (`VITS`) as its tags in order.
final class TagStoreSection extends TypedSection {
  const TagStoreSection({required this.tags, super.index, super.compressed})
    : super('VITS');

  factory TagStoreSection.of(
    ViTagStore store, {
    int index = 0,
    bool compressed = false,
  }) => TagStoreSection(
    tags: [
      for (final entry in store.entries)
        TagSpec(
          name: entry.name,
          value: _copy(entry.value),
          framing: entry.framing,
        ),
    ],
    index: index,
    compressed: compressed,
  );

  final List<TagSpec> tags;

  @override
  Uint8List get payload => ViTagStore.encode([
    for (final tag in tags)
      (name: tag.name, framing: tag.framing, value: tag.value),
  ]);

  @override
  String get constructor => 'TagStoreSection';

  @override
  List<(String, Object?)> get arguments => [('tags', tags)];
}

/// One tag: its name and its flattened variant value, framed as [framing] says.
final class TagSpec implements Spelled {
  const TagSpec({
    required this.name,
    required this.value,
    this.framing = ViTagValueFraming.lengthPrefixed,
  });

  final String name;

  final Uint8List value;

  final ViTagValueFraming framing;

  @override
  String get constructor => 'TagSpec';

  @override
  List<(String, Object?)> get arguments => [
    ('name', name),
    ('value', value),
    if (framing != ViTagValueFraming.lengthPrefixed) ('framing', framing),
  ];
}

/// A save record (`LVSR`), its optional trailing fields present up to the last one given.
final class SaveRecordSection extends TypedSection {
  const SaveRecordSection({
    required this.versionWord,
    required this.statusFlags,
    required this.optionFlags,
    required this.flags12,
    required this.unknown16,
    required this.windowFlags,
    required this.hiddenButtons,
    required this.frontPanelFlags,
    required this.stateFlags,
    required this.unknown28,
    required this.priority,
    required this.viType,
    required this.executionSystem,
    required this.unknown40,
    required this.unknown52,
    required this.frontPanelGrid,
    required this.blockDiagramGrid,
    required this.unknown76,
    required this.controlStyle,
    required this.unknown80,
    this.unknown96,
    this.unknown112,
    this.unknown116,
    this.unknown120,
    this.unknown136,
    this.unknown137,
    this.unknown140,
    this.unknown144,
    super.index,
    super.compressed,
  }) : super('LVSR');

  factory SaveRecordSection.of(
    ViSaveRecord record, {
    int index = 0,
    bool compressed = false,
  }) => SaveRecordSection(
    versionWord: record.versionWordBits,
    statusFlags: record.statusFlagWord,
    optionFlags: record.optionFlagWord,
    flags12: record.flags12,
    unknown16: record.unknown16,
    windowFlags: record.windowFlagWord,
    hiddenButtons: record.hiddenButtonWord,
    frontPanelFlags: record.frontPanelFlagWord,
    stateFlags: record.stateFlagWord,
    unknown28: record.unknown28,
    priority: record.priority,
    viType: record.kind,
    executionSystem: record.executionSystem,
    unknown40: _copy(record.unknown40),
    unknown52: _copy(record.unknown52),
    frontPanelGrid: record.frontPanelGrid,
    blockDiagramGrid: record.blockDiagramGrid,
    unknown76: record.unknown76,
    controlStyle: record.controlStyle,
    unknown80: _copy(record.unknown80),
    unknown96: _copyOrNull(record.unknown96),
    unknown112: record.unknown112,
    unknown116: record.unknown116,
    unknown120: _copyOrNull(record.unknown120),
    unknown136: record.unknown136,
    unknown137: _copyOrNull(record.unknown137),
    unknown140: record.unknown140,
    unknown144: _copyOrNull(record.unknown144),
    index: index,
    compressed: compressed,
  );

  final int versionWord;
  final int statusFlags;
  final int optionFlags;
  final int flags12;
  final int unknown16;
  final int windowFlags;
  final int hiddenButtons;
  final int frontPanelFlags;
  final int stateFlags;
  final int unknown28;
  final ViPriority priority;
  final ViKind viType;
  final ViExecutionSystem executionSystem;
  final Uint8List unknown40;
  final Uint8List unknown52;
  final int frontPanelGrid;
  final int blockDiagramGrid;
  final int unknown76;
  final ViControlStyle controlStyle;
  final Uint8List unknown80;
  final Uint8List? unknown96;
  final int? unknown112;
  final int? unknown116;
  final Uint8List? unknown120;
  final int? unknown136;
  final Uint8List? unknown137;
  final int? unknown140;
  final Uint8List? unknown144;

  @override
  Uint8List get payload => ViSaveRecord.encode(
    versionWord: versionWord,
    statusFlags: statusFlags,
    optionFlags: optionFlags,
    flags12: flags12,
    unknown16: unknown16,
    windowFlags: windowFlags,
    hiddenButtons: hiddenButtons,
    frontPanelFlags: frontPanelFlags,
    stateFlags: stateFlags,
    unknown28: unknown28,
    priority: priority,
    viType: viType,
    executionSystem: executionSystem,
    unknown40: unknown40,
    unknown52: unknown52,
    frontPanelGrid: frontPanelGrid,
    blockDiagramGrid: blockDiagramGrid,
    unknown76: unknown76,
    controlStyle: controlStyle,
    unknown80: unknown80,
    unknown96: unknown96,
    unknown112: unknown112,
    unknown116: unknown116,
    unknown120: unknown120,
    unknown136: unknown136,
    unknown137: unknown137,
    unknown140: unknown140,
    unknown144: unknown144,
  );

  @override
  String get constructor => 'SaveRecordSection';

  @override
  List<(String, Object?)> get arguments => [
    ('versionWord', HexInt(versionWord)),
    ('statusFlags', HexInt(statusFlags)),
    ('optionFlags', HexInt(optionFlags)),
    ('flags12', HexInt(flags12)),
    ('unknown16', unknown16),
    ('windowFlags', HexInt(windowFlags)),
    ('hiddenButtons', HexInt(hiddenButtons)),
    ('frontPanelFlags', HexInt(frontPanelFlags)),
    ('stateFlags', HexInt(stateFlags)),
    ('unknown28', unknown28),
    ('priority', priority),
    ('viType', viType),
    ('executionSystem', executionSystem),
    ('unknown40', unknown40),
    ('unknown52', unknown52),
    ('frontPanelGrid', frontPanelGrid),
    ('blockDiagramGrid', blockDiagramGrid),
    ('unknown76', unknown76),
    ('controlStyle', controlStyle),
    ('unknown80', unknown80),
    ('unknown96', unknown96),
    ('unknown112', _hexOrNull(unknown112)),
    ('unknown116', unknown116),
    ('unknown120', unknown120),
    ('unknown136', unknown136),
    ('unknown137', unknown137),
    ('unknown140', _hexOrNull(unknown140)),
    ('unknown144', unknown144),
  ];
}

Uint8List _copy(Uint8List bytes) => Uint8List.fromList(bytes);

Uint8List? _copyOrNull(Uint8List? bytes) =>
    bytes == null ? null : Uint8List.fromList(bytes);

HexInt? _hexOrNull(int? value) => value == null ? null : HexInt(value);

/// A block-diagram password record (`BDPW`): three digests, or two.
final class PasswordSection extends TypedSection {
  const PasswordSection({
    required this.passwordDigest,
    required this.digest2,
    this.digest3,
    super.index,
    super.compressed,
  }) : super('BDPW');

  factory PasswordSection.of(
    ViPasswordRecord record, {
    int index = 0,
    bool compressed = false,
  }) => PasswordSection(
    passwordDigest: _copy(record.passwordDigest),
    digest2: _copy(record.digest2),
    digest3: _copyOrNull(record.digest3),
    index: index,
    compressed: compressed,
  );

  final Uint8List passwordDigest;

  final Uint8List digest2;

  final Uint8List? digest3;

  @override
  Uint8List get payload => ViPasswordRecord.encode(
    passwordDigest: passwordDigest,
    digest2: digest2,
    digest3: digest3,
  );

  @override
  String get constructor => 'PasswordSection';

  @override
  List<(String, Object?)> get arguments => [
    ('passwordDigest', passwordDigest),
    ('digest2', digest2),
    ('digest3', digest3),
  ];
}

/// A signature (`RTSG`, `OBSG`, `CCSG`): one digest.
final class SignatureSection extends TypedSection {
  const SignatureSection({
    required String tag,
    required this.digest,
    super.index,
    super.compressed,
  }) : super(tag);

  factory SignatureSection.of(
    String tag,
    ViSignature signature, {
    int index = 0,
    bool compressed = false,
  }) => SignatureSection(
    tag: tag,
    digest: _copy(signature.digest),
    index: index,
    compressed: compressed,
  );

  final Uint8List digest;

  @override
  Uint8List get payload => ViSignature.encode(digest);

  @override
  String get constructor => 'SignatureSection';

  @override
  List<(String, Object?)> get arguments => [('tag', tag), ('digest', digest)];
}

/// Link info (`LIvi`, `LIbd`, `LIfp`, `LIds`): its entries by kind, each body as bytes, and any
/// region the entry grammar does not walk as [unwalked]; [qualifiedName] and [words] are the
/// library form's header.
final class LinkInfoSection extends TypedSection {
  const LinkInfoSection({
    required String tag,
    this.version = 1,
    required this.rootKind,
    this.qualifiedName,
    this.words = const [],
    this.entryCount,
    required this.entries,
    this.unwalked,
    this.terminator = 3,
    super.index,
    super.compressed,
  }) : super(tag);

  factory LinkInfoSection.of(
    String tag,
    ViLinkInfo info, {
    int index = 0,
    bool compressed = false,
  }) {
    final bytes = Uint8List.sublistView(info.view);
    final framed = info.entries.whereType<ViLinkEntryFramed>().toList();
    final rest = info.entries.whereType<ViLinkEntryUnwalked>().firstOrNull;
    return LinkInfoSection(
      tag: tag,
      version: info.version,
      rootKind: info.rootKind,
      qualifiedName: info.qualifiedName,
      words: info.words ?? const [],
      entryCount: rest == null ? null : info.entryCount,
      entries: [
        for (final entry in framed)
          LinkEntrySpec(
            version: info.view.getUint16(
              entry.offset + LinkInfoEntry.version.offset,
            ),
            kind: entry.kind,
            body: bytes.sublist(
              entry.offset + LinkInfoEntry.body.offset,
              entry.end,
            ),
          ),
      ],
      unwalked: rest == null ? null : bytes.sublist(rest.offset, rest.end),
      terminator: info.terminator,
      index: index,
      compressed: compressed,
    );
  }

  final int version;

  final String rootKind;

  final String? qualifiedName;

  final List<int> words;

  /// The stored entry count when [unwalked] holds entries; null when it is [entries]' length.
  final int? entryCount;

  final List<LinkEntrySpec> entries;

  final Uint8List? unwalked;

  final int terminator;

  @override
  Uint8List get payload => ViLinkInfo.encode(
    version: version,
    rootKind: rootKind,
    qualifiedName: qualifiedName,
    words: words,
    entryCount: entryCount,
    entries: [
      for (final entry in entries)
        (version: entry.version, kind: entry.kind, body: entry.body),
    ],
    unwalked: unwalked ?? const [],
    terminator: terminator,
  );

  @override
  String get constructor => 'LinkInfoSection';

  @override
  List<(String, Object?)> get arguments => [
    ('tag', tag),
    if (version != 1) ('version', version),
    ('rootKind', rootKind),
    ('qualifiedName', qualifiedName),
    if (words.isNotEmpty) ('words', words),
    ('entryCount', entryCount),
    ('entries', entries),
    ('unwalked', unwalked),
    if (terminator != 3) ('terminator', terminator),
  ];
}

/// One link entry: its [kind] and the body its grammar reads, as bytes.
final class LinkEntrySpec implements Spelled {
  const LinkEntrySpec({
    this.version = 2,
    required this.kind,
    required this.body,
  });

  final int version;

  final String kind;

  final Uint8List body;

  @override
  String get constructor => 'LinkEntrySpec';

  @override
  List<(String, Object?)> get arguments => [
    if (version != 2) ('version', version),
    ('kind', kind),
    ('body', body),
  ];
}
