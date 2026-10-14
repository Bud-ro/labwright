import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// Everything decoded from one VI that the inspector and transpiler consume: the version and
/// title, per-block component totals, the diagrams of both sides, the type pool, the sub-VI
/// names, the connector-pane type and the font table; and the sections themselves, which
/// edits change and [serialize] writes back into the file they were loaded from.
class ViModel {
  ViModel({
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

  /// The section of [tag] at [index] among the block's sections, or null when the file has
  /// none.
  ViSectionBuffer? section(String tag, [int index = 0]) {
    for (final section in sections) {
      if (section.tag == tag && section.index == index) return section;
    }
    return null;
  }

  /// A fresh object id for a heap object: one above the highest in use, which `MUID` now
  /// records.
  int allocateUid() {
    final record = ViMaxUid(section(BlockTag.muid.tag)!.writable);
    return record.maxUid += 1;
  }

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
  List<ViType> types;

  /// The VI's call signature from `CONP`: one parameter per pane terminal; null without `CONP`.
  ViType? connectorPaneType;

  /// The panel control behind each connector-pane terminal, in pane order; null where the
  /// terminal is unwired or no control answers for it. See [connectorPaneTerminals].
  List<ViHeapObject?> paneTerminals;

  /// Appends [descriptor] to the type pool and returns its index.
  int addType(Uint8List descriptor) {
    final vctp = section(BlockTag.vctp.tag)!;
    final pool = ViTypePool(vctp.bytes);
    final index = pool.length;
    vctp.splice(pool.descriptorsEnd, pool.descriptorsEnd, descriptor);
    ViTypePool.count.write(ByteData.sublistView(vctp.writable), index + 1);
    reloadTypes();
    return index;
  }

  /// Replaces the descriptor at [index] with [descriptor].
  void replaceType(int index, Uint8List descriptor) {
    final type = types[index];
    section(BlockTag.vctp.tag)!.splice(type.offset, type.end, descriptor);
    reloadTypes();
  }

  /// Makes [indices] the pool's top-level types, in that order.
  void setTopLevelTypes(List<int> indices) {
    final vctp = section(BlockTag.vctp.tag)!;
    final pool = ViTypePool(vctp.bytes);
    vctp.splice(pool.descriptorsEnd, vctp.length, [
      indices.length >> 8 & 0xff,
      indices.length & 0xff,
      for (final index in indices) ...[index >> 8 & 0xff, index & 0xff],
    ]);
    reloadTypes();
  }

  /// The heap section [diagram] was built from.
  ViSectionBuffer sectionOf(ViDiagram diagram) => section(diagram.sectionTag, diagram.sectionIndex)!;

  /// Moves [object] by ([dx], [dy]): its bounds record is rewritten in place, and the absolute
  /// bounds of everything inside it follow.
  void moveObject(ViDiagram diagram, ViHeapObject object, {required int dx, required int dy}) {
    final at = object.boundsOffset;
    final bounds = object.bounds;
    if (at == null || bounds == null) throw ArgumentError('object ${object.oid} has no bounds record');
    final moved = HeapRect(
      top: bounds.top + dy,
      left: bounds.left + dx,
      bottom: bounds.bottom + dy,
      right: bounds.right + dx,
    );
    ByteData.sublistView(sectionOf(diagram).writable)
      ..setInt16(at, moved.top)
      ..setInt16(at + 2, moved.left)
      ..setInt16(at + 4, moved.bottom)
      ..setInt16(at + 6, moved.right);
    object.bounds = moved;
    void follow(ViHeapObject inner) {
      if (inner.absBounds case final abs?) {
        inner.absBounds = HeapRect(
          top: abs.top + dy,
          left: abs.left + dx,
          bottom: abs.bottom + dy,
          right: abs.right + dx,
        );
      }
      for (final child in diagram.childrenOf(inner)) {
        follow(child);
      }
    }

    follow(object);
  }

  /// Gives [object] the label [text], written as its code units in place of its label record.
  void setLabel(ViDiagram diagram, ViHeapObject object, String text) {
    final at = object.labelOffset;
    if (at == null) throw ArgumentError('object ${object.oid} has no label record');
    final record = encodeHeapC4Record(HeapOpcode.caption.byte, text.codeUnits);
    sectionOf(diagram).splice(at, at + object.labelLength, record);
    final delta = record.length - object.labelLength;
    final named = diagram.parentOf(object);
    if (named != null && named.labelOffset == null && named.label == object.label?.trim()) named.label = text.trim();
    object
      ..label = text
      ..labelLength = record.length;
    _shiftHeap(diagram, at, delta);
  }

  /// Moves every heap offset after [at] by [delta], after a splice there.
  void _shiftHeap(ViDiagram diagram, int at, int delta) {
    if (delta == 0) return;
    for (final object in diagram.objects) {
      if (object.offset > at) object.offset += delta;
      if (object.end > at) object.end += delta;
      if (object.boundsOffset case final bounds? when bounds > at) object.boundsOffset = bounds + delta;
      if (object.labelOffset case final label? when label > at) object.labelOffset = label + delta;
    }
  }

  /// Rebuilds what the type pool decides, after `VCTP` changed: [types], every heap object's
  /// resolved type, [connectorPaneType] and [paneTerminals].
  void reloadTypes() {
    final pool = switch (section(BlockTag.vctp.tag)) {
      final vctp? => ViTypePool(vctp.bytes),
      null => null,
    };
    types = pool?.types ?? const <ViType>[];
    for (final diagram in diagrams) {
      for (final object in diagram.objects) {
        object
          ..dataType = null
          ..resolvedType = null
          ..resolvedElementType = null
          ..resolvedMembers = const []
          ..resolvedElementMembers = const [];
      }
    }
    resolveDataSpaceTypes(
      pool: types,
      table: pool?.topLevelIndices ?? const [],
      typeIndexBase: switch (section(BlockTag.dthp.tag)) {
        final dthp? => switch (ViDataTypeHeap(dthp.bytes)) {
          ViDataTypeHeapCompact(:final viTypeIndexBase) => viTypeIndexBase,
          _ => null,
        },
        null => null,
      },
      blockDiagrams: blockDiagrams,
      frontPanelDiagrams: frontPanelDiagrams,
    );
    connectorPaneType = switch (section(BlockTag.conp.tag)) {
      final conp? => ViConnectorPane(conp.bytes).typeIn(pool),
      null => null,
    };
    paneTerminals = connectorPaneTerminals(
      paneType: connectorPaneType,
      frontPanelDiagrams: frontPanelDiagrams,
      map: switch (section(BlockTag.cpmp.tag)) {
        final cpmp? => ViConnectorPaneMap(cpmp.bytes),
        null => null,
      },
      panelType: switch (section(BlockTag.fptd.tag)) {
        final fptd? => ViFrontPanelType(fptd.bytes),
        null => null,
      },
      pool: pool,
    );
  }

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
        buildDiagram(
          decodedSection.bytes,
          sectionTag: decodedSection.tag,
          version: ver.version,
          sectionIndex: decodedSection.index,
        ),
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
    fontTable: fontTable,
    version: ver.version,
    title: ver.title,
    components: componentsFromDecoded(list),
    blockDiagrams: blockDiagrams,
    frontPanelDiagrams: frontPanelDiagrams,
  )..reloadTypes();
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
