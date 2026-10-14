import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'vi_spec.dart';

/// The typed form of [section] decoded through its block's view, or null when the tag has
/// none or the payload does not fit the view; [version] is the saving version `vers` gives.
TypedSection? typedSectionOf(DecodedSection section, {ViVersionWord? version}) {
  final DecodedSection(:tag, :bytes, :index, wasCompressed: compressed) =
      section;
  if (LegacyIconDepth.forTag(tag) case final depth?
      when bytes.length == depth.byteLength) {
    return IconSection.of(
      ViLegacyIcon(bytes, depth),
      index: index,
      compressed: compressed,
    );
  }
  if (tag == BlockTag.vits.tag) {
    return TagStoreSection.of(
      ViTagStore(bytes),
      index: index,
      compressed: compressed,
    );
  }
  return null;
}

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
          value: Uint8List.fromList(entry.value),
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
