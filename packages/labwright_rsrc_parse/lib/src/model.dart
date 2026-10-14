import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// Everything decoded from one VI that the inspector and transpiler consume: the version and
/// title, per-block component totals, the diagrams of both sides, the type pool, the sub-VI
/// names, the connector-pane type and the font table; and the sections themselves, which
/// edits change and [serialize] writes back into the file they were loaded from.
class ViModel {
  const ViModel({
    required this.version,
    required this.title,
    required this.components,
    this.sections = const <ViSectionBuffer>[],
    this.file,
    this.blockDiagrams = const <ViDiagram>[],
    this.frontPanelDiagrams = const <ViDiagram>[],
    this.subViNames = const <String>[],
    this.types = const <ViType>[],
    this.connectorPaneType,
    this.paneTerminals = const <ViHeapObject?>[],
    this.fontTable,
  });

  /// The version string from `vers`.
  final String? version;

  /// The title from `vers`.
  final String? title;

  final List<BlockComponent> components;

  /// The file's own sections, in file order, each holding its inflated payload.
  final List<ViSectionBuffer> sections;

  /// The container the sections were loaded from, null for a model built without a file.
  final ViVi? file;

  /// The file with every edited section written back: a section that was stored compressed
  /// is deflated again, the rest are copied as loaded.
  Uint8List serialize() {
    final file = this.file;
    if (file == null) throw StateError('the model was built without a file to write into');
    return file.withSectionPayloads({
      for (final section in sections)
        if (section.edited && section.secRel != null)
          section.secRel!: section.compressed ? deflateHeapPayload(section.bytes) : section.bytes,
    }).serialize();
  }

  /// One diagram per `BDHb` section.
  final List<ViDiagram> blockDiagrams;

  /// One diagram per `FPHb` section.
  final List<ViDiagram> frontPanelDiagrams;

  ViDiagram? get primaryBlockDiagram => largestDiagram(blockDiagrams);

  /// Sub-VI names recovered from `LIbd`, see [readSubViNames].
  final List<String> subViNames;

  /// The `VCTP` type pool.
  final List<ViType> types;

  /// The VI's call signature from `CONP`: one parameter per pane terminal; null without `CONP`.
  final ViType? connectorPaneType;

  /// The panel control behind each connector-pane terminal, in pane order; null where the
  /// terminal is unwired or no control answers for it. See [connectorPaneTerminals].
  final List<ViHeapObject?> paneTerminals;

  final ViFontTable? fontTable;

  List<ViDiagram> get diagrams => [...blockDiagrams, ...frontPanelDiagrams];
}

/// Decodes every section of a VI and builds its [ViModel], which [ViModel.serialize] writes
/// back into [viBytes]'s container.
ViModel buildViModel(Uint8List viBytes) {
  final sections = readViSections(viBytes);
  return buildViModelFromDecoded(
    [for (final section in sections) inflateSection(section)],
    subViNames: subViNamesOf(sections, viBytes),
    file: viBytes,
  );
}

/// The model over [decoded]; with [file], the bytes they were read from, the model also holds
/// the container that [ViModel.serialize] writes into.
ViModel buildViModelFromDecoded(
  Iterable<DecodedSection> decoded, {
  List<String> subViNames = const <String>[],
  Uint8List? file,
}) {
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
  final fontTable = ftab == null ? null : ViFontTable(ftab);
  if (fontTable != null) {
    for (final diagram in [...blockDiagrams, ...frontPanelDiagrams]) {
      for (final object in diagram.objects) {
        if (object.textStyleRuns.isEmpty) continue;
        object.labelFont = fontTable.entryForRunFontId(object.textStyleRuns.first.fontId);
      }
    }
  }
  final vctp = list.where((s) => s.tag == 'VCTP').map((s) => s.bytes).firstOrNull;
  final pool = vctp == null ? null : ViTypePool(vctp);
  final types = pool?.types ?? const <ViType>[];
  final dthp = list.where((s) => s.tag == 'DTHP').map((s) => s.bytes).firstOrNull;
  resolveDataSpaceTypes(
    pool: types,
    table: pool?.topLevelIndices ?? const [],
    typeIndexBase: switch (dthp == null ? null : ViDataTypeHeap(dthp)) {
      ViDataTypeHeapCompact(:final viTypeIndexBase) => viTypeIndexBase,
      _ => null,
    },
    blockDiagrams: blockDiagrams,
    frontPanelDiagrams: frontPanelDiagrams,
  );
  final paneType = switch (list.where((section) => section.tag == 'CONP').firstOrNull) {
    final DecodedSection conp => ViConnectorPane(conp.bytes).typeIn(pool),
    null => null,
  };
  final cpmp = list.where((s) => s.tag == 'CPMp').map((s) => s.bytes).firstOrNull;
  final fptd = list.where((s) => s.tag == 'FPTD').map((s) => s.bytes).firstOrNull;
  return ViModel(
    sections: [
      for (final section in list)
        ViSectionBuffer(
          section.tag,
          section.index,
          section.bytes,
          compressed: section.wasCompressed,
          secRel: section.section.dataOffset,
        ),
    ],
    file: file == null ? null : ViVi.parse(file),
    subViNames: subViNames,
    types: types,
    fontTable: fontTable,
    connectorPaneType: paneType,
    paneTerminals: connectorPaneTerminals(
      paneType: paneType,
      frontPanelDiagrams: frontPanelDiagrams,
      map: cpmp == null ? null : ViConnectorPaneMap(cpmp),
      panelType: fptd == null ? null : ViFrontPanelType(fptd),
      pool: pool,
    ),
    version: ver.version,
    title: ver.title,
    components: componentsFromDecoded(list),
    blockDiagrams: blockDiagrams,
    frontPanelDiagrams: frontPanelDiagrams,
  );
}

/// The diagram with the most placed objects, or null when none has any.
ViDiagram? largestDiagram(List<ViDiagram> diagrams) {
  ViDiagram? best;
  var bestCount = 0;
  for (final diagram in diagrams) {
    var count = 0;
    for (final object in diagram.objects) {
      if (object.absBounds != null) count++;
    }
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
