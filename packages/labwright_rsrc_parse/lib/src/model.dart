import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// Everything decoded from one VI that the inspector and transpiler consume: the version and
/// title, per-block component totals, the C4 records, the diagrams of both sides, the type
/// pool, the sub-VI names, the connector-pane type and the font table.
class ViModel {
  const ViModel({
    required this.version,
    required this.title,
    this.description,
    required this.components,
    required this.heapRecords,
    this.blockDiagrams = const <ViDiagram>[],
    this.frontPanelDiagrams = const <ViDiagram>[],
    this.subViNames = const <String>[],
    this.types = const <ViType>[],
    this.connectorPaneTypeIndex,
    this.fontTable,
  });

  /// The version string from `vers`.
  final String? version;

  /// The title from `vers`.
  final String? title;

  /// Text found in `CPC2`, see [cpc2Description].
  final String? description;

  final List<BlockComponent> components;

  /// Every C4 record across the heap sections, in file order.
  final List<HeapRecord> heapRecords;

  /// One diagram per `BDHb` section.
  final List<ViDiagram> blockDiagrams;

  /// One diagram per `FPHb` section.
  final List<ViDiagram> frontPanelDiagrams;

  ViDiagram? get primaryBlockDiagram => largestDiagram(blockDiagrams);

  /// Sub-VI names recovered from `LIbd`, see [readSubViNames].
  final List<String> subViNames;

  /// The `VCTP` type pool.
  final List<ViType> types;

  /// The 1-based `VCTP` index of the connector-pane type; null without `CONP` or when the
  /// pane carries an inline descriptor.
  final int? connectorPaneTypeIndex;

  final ViFontTable? fontTable;

  List<ViDiagram> get diagrams => [...blockDiagrams, ...frontPanelDiagrams];

  List<String> _dedupe(Iterable<String?> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value != null && seen.add(value)) value,
    ];
  }

  List<String> get captions => _dedupe([
    for (final record in heapRecords)
      if (record.kind == HeapOpcode.caption) record.text,
  ]);

  List<String> get symbolNames => _dedupe([
    for (final record in heapRecords)
      if (record.kind == HeapOpcode.symbolName) record.text,
  ]);

  List<String> get paths => _dedupe([for (final record in heapRecords) record.path]);

  List<String> get descriptions => _dedupe([for (final record in heapRecords) record.descriptionText]);
}

/// Decodes every section of a VI and builds its [ViModel].
ViModel buildViModel(Uint8List viBytes) =>
    buildViModelFromDecoded(decodeSections(viBytes), subViNames: readSubViNames(viBytes));

ViModel buildViModelFromDecoded(Iterable<DecodedSection> decoded, {List<String> subViNames = const <String>[]}) {
  final list = decoded is List<DecodedSection> ? decoded : decoded.toList();
  final sections = list.map((d) => d.section).toList();
  final ver = versionFromSections(sections);
  List<ViDiagram> diagramsFor(BlockTag heap) => [
    for (final decodedSection in list)
      if (decodedSection.tag == heap.tag && decodedSection.bytes.length >= 6)
        buildDiagram(decodedSection.bytes, sectionTag: decodedSection.tag, version: ver.version),
  ];
  final blockDiagrams = diagramsFor(BlockTag.bdhb);
  final frontPanelDiagrams = diagramsFor(BlockTag.fphb);
  final ftab = list.where((s) => s.tag == 'FTAB').map((s) => s.bytes).firstOrNull;
  final fontTable = ftab == null ? null : decodeFontTable(ftab);
  if (fontTable != null) {
    for (final diagram in [...blockDiagrams, ...frontPanelDiagrams]) {
      for (final object in diagram.objects) {
        if (object.textStyleRuns.isEmpty) continue;
        object.labelFont = fontTable.entryForRunFontId(object.textStyleRuns.first.fontId);
      }
    }
  }
  final vctp = list.where((s) => s.tag == 'VCTP').map((s) => s.bytes).firstOrNull;
  final pool = vctp == null ? null : decodeTypePool(vctp);
  final types = pool?.types ?? const <ViType>[];
  final dthp = list.where((s) => s.tag == 'DTHP').map((s) => s.bytes).firstOrNull;
  resolveDataSpaceTypes(
    pool: types,
    table: pool?.topLevelIndices ?? const [],
    typeIndexBase: switch (dthp == null ? null : decodeDataTypeHeap(dthp)) {
      ViDataTypeHeapCompact(:final viTypeIndexBase) => viTypeIndexBase,
      _ => null,
    },
    blockDiagrams: blockDiagrams,
    frontPanelDiagrams: frontPanelDiagrams,
  );
  return ViModel(
    subViNames: subViNames,
    types: types,
    fontTable: fontTable,
    connectorPaneTypeIndex: switch (connectorPaneFromSections(sections)) {
      ViConnectorPaneTypeIndex(:final typeIndex) => typeIndex,
      ViConnectorPaneInline() || null => null,
    },
    version: ver.version,
    title: ver.title,
    description: cpc2Description(sections),
    components: componentsFromDecoded(list),
    heapRecords: heapC4RecordsFromDecoded(list),
    blockDiagrams: blockDiagrams,
    frontPanelDiagrams: frontPanelDiagrams,
  );
}

/// The diagram with the most placed objects, or null when none has any.
ViDiagram? largestDiagram(List<ViDiagram> diagrams) {
  ViDiagram? best;
  var bestCount = 0;
  for (final diagram in diagrams) {
    final count = diagram.objects.where((o) => o.absBounds != null).length;
    if (count > bestCount) {
      best = diagram;
      bestCount = count;
    }
  }
  return best;
}

/// The glyph LabVIEW paints on a terminal of the type, or null when the type has none.
String? dataTypeGlyph(ViDataType type) => switch (type) {
  ViDataType.i8 => 'I8',
  ViDataType.i16 => 'I16',
  ViDataType.i32 => 'I32',
  ViDataType.i64 => 'I64',
  ViDataType.u8 => 'U8',
  ViDataType.u16 => 'U16',
  ViDataType.u32 => 'U32',
  ViDataType.u64 => 'U64',
  ViDataType.sgl => 'SGL',
  ViDataType.dbl => 'DBL',
  ViDataType.ext => 'EXT',
  ViDataType.complexSgl => 'CSG',
  ViDataType.complexDbl => 'CDB',
  ViDataType.complexExt => 'CXT',
  ViDataType.boolean => 'TF',
  ViDataType.string || ViDataType.cString => 'abc',
  _ => null,
};
