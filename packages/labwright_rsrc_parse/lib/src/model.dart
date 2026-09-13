import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// Everything decoded from one VI that the inspector and transpiler consume: the version and
/// title, per-block component totals, the recovered string tables and C4 records, the diagrams
/// of both sides, the type pool, the sub-VI names, the connector-pane type and the font table.
class ViModel {
  const ViModel({
    required this.version,
    required this.title,
    this.description,
    required this.components,
    required this.stringTables,
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

  final List<HeapStringTable> stringTables;

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

  List<HeapRect> get objectBounds => heapRecords.map((r) => r.bounds).whereType<HeapRect>().toList();

  List<ViObject> get objects => assembleObjects(heapRecords, stringTables);

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

  List<String> get labels => _dedupe(stringTables.expand((t) => t.strings));
}

/// A bounds rectangle paired with the caption or string table that follows it in the heap,
/// see [assembleObjects].
class ViObject {
  const ViObject({
    required this.sectionTag,
    required this.bounds,
    this.caption,
    this.labels = const <String>[],
  });

  final String sectionTag;

  final HeapRect bounds;

  final String? caption;

  final List<String> labels;

  String? get name => caption ?? (labels.isEmpty ? null : labels.first);
}

/// Pairs each caption or framed string-table record with the bounds record at most
/// [maxRecordGap] records before it in the same section.
List<ViObject> assembleObjects(List<HeapRecord> records, List<HeapStringTable> stringTables, {int maxRecordGap = 3}) {
  final framed = {
    for (final table in stringTables)
      if (table.framed) '${table.sectionTag}@${table.offset}': table,
  };

  final out = <ViObject>[];
  HeapRect? lastBounds;
  var lastBoundsIdx = -1;
  String? section;
  var idx = 0;
  void attach(ViObject o) {
    out.add(o);
    lastBounds = null;
  }

  for (final record in records) {
    if (record.sectionTag != section) {
      section = record.sectionTag;
      lastBounds = null;
      lastBoundsIdx = -1;
    }
    final pendingBounds = idx - lastBoundsIdx <= maxRecordGap ? lastBounds : null;
    final recordBounds = record.bounds;
    if (record.kind == HeapOpcode.bounds && recordBounds != null) {
      lastBounds = recordBounds;
      lastBoundsIdx = idx;
    } else if (record.kind == HeapOpcode.caption && pendingBounds != null) {
      final cap = record.text;
      if (cap != null) {
        attach(
          ViObject(
            sectionTag: record.sectionTag,
            bounds: pendingBounds,
            caption: cap,
          ),
        );
      }
    } else if (record.kind == HeapOpcode.stringTable && pendingBounds != null) {
      final table = framed['${record.sectionTag}@${record.offset + record.headerLength}'];
      if (table != null) {
        attach(
          ViObject(
            sectionTag: record.sectionTag,
            bounds: pendingBounds,
            labels: table.strings,
          ),
        );
      }
    }
    idx++;
  }
  return out;
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
  final types = vctp == null ? const <ViType>[] : decodeTypePool(vctp);
  final dthp = list.where((s) => s.tag == 'DTHP').map((s) => s.bytes).firstOrNull;
  resolveDataSpaceTypes(
    pool: types,
    table: vctp == null ? const [] : decodeTypeTable(vctp),
    typeIndexBase: dthp == null ? null : decodeDataTypeHeap(dthp)?.viTypeIndexBase,
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
    stringTables: heapStringTablesFromDecoded(list),
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
