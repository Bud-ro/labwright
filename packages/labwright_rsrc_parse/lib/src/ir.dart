import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// A read-only, **partial-fidelity** model of a decoded VI — the Stage 4 IR seed.
///
/// This aggregates the layers that are **reliably decoded and corpus-validated**
/// into one structure: container/block component sizes, the LabVIEW version +
/// embedded title, the grouped string tables (control/enum labels), and the
/// length-prefixed `C4` leaf records of the heap. It is the documented **plug-in
/// point** for a future VI→Dart auto-translator (Stage 5): the translator
/// consumes a [ViModel] rather than re-parsing bytes, so new heap-decoding work
/// flows into translation by enriching this model.
///
/// Fidelity is deliberately **partial and honest**. The heap's nested object
/// tree IS now recovered into [diagrams] (objects with bounds, labels, class
/// codes and parent/child nesting — see `buildDiagram`), including the
/// dataflow **wires** ([ViDiagram.wires]: endpoint binding, route geometry,
/// and a datatype ESTIMATE that agrees with typed endpoints ~9-in-10 — see
/// [ViWire.typeKind]). Not *yet* decoded is wire **direction** (which
/// endpoint is the source); function-vs-subVI is likewise not yet
/// distinguished from the block diagram alone.
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

  /// LabVIEW version the VI was saved in (e.g. `10.0`), or null if not yet recovered.
  final String? version;

  /// The VI's embedded title/description (from the `vers` block), or null.
  final String? title;

  /// The VI's top-level description / help text (from the `CPC2` block), or null.
  final String? description;

  /// Per-block size summary (block diagram / front panel / type data weights),
  /// largest decompressed first.
  final List<BlockComponent> components;

  /// String tables (grouped labels: enum/ring items, captions, …), order- and
  /// offset-preserving. Tables framed by the confirmed `C4 2E` opcode carry
  /// [HeapStringTable.framed] == true.
  final List<HeapStringTable> stringTables;

  /// The length-prefixed `C4` leaf records of the heaps (the reliably-framed
  /// objects: string tables, `C4 2D`/`1F` value records, …).
  final List<HeapRecord> heapRecords;

  /// The recovered **block-diagram** object tree(s) — from the `BDHb`/`BDHP`
  /// block-diagram heaps: objects (structures / nodes / control terminals /
  /// labels) with bounds, labels, classified [HeapObjectClass], and parent/child
  /// nesting (`parentOid` + child-membership refs), plus the dataflow **wires**
  /// ([ViDiagram.wires]): signal (`0x17`) objects with resolved oid endpoint
  /// binding + endpoint anchors, stored route geometry, and the decoded wire
  /// datatype ([ViWire.signalType] — an estimate with measured ~90% family
  /// agreement against typed endpoints, see [ViWire.typeKind]). **Scope**:
  /// wire direction is not decoded (see [ViWire]).
  final List<ViDiagram> blockDiagrams;

  /// The recovered **front-panel** object tree(s) — from the `FPHb`/`FPHP`
  /// front-panel heaps: the panel's controls/indicators/decorations with bounds
  /// and labels. Same heap-tree format as [blockDiagrams]; semantically the
  /// panel layout rather than the diagram. (Which heap actually carries content
  /// varies per VI/save-format — see `corpus/`.)
  final List<ViDiagram> frontPanelDiagrams;

  /// The names of the **subVIs this VI calls**, recovered from the block-diagram
  /// linker block (`LIbd`) by `readSubViNames` — deduped, order-preserving, the
  /// VI's own name excluded. Honest VI-level dependency info: it lists *which*
  /// subVIs are called, not which node calls which (that linkage is not yet
  /// recovered from the diagram). Empty when none are stored (or when built
  /// via [buildViModelFromDecoded], which has no raw container bytes).
  final List<String> subViNames;

  /// The VI's **data-type pool** (`VCTP`) — the ordered list of type descriptors
  /// the VI defines, recovered by `decodeTypePool`: kind ([ViDataType]) + raw
  /// code, plus the recovered name, cluster members, array element, and enum
  /// items where present (uncatalogued codes keep their raw byte). Empty when the
  /// pool is absent/unparseable.
  final List<ViType> types;

  /// 1-based `VCTP` index of the VI's connector-pane type (from the `CONP`
  /// block), or null when absent. Resolve against [types] for the VI's interface
  /// terminals (a cluster's members are the terminals; in/out direction is not
  /// recovered). Corpus-confirmed in-range for CONP (see decodeConnectorPane).
  final int? connectorPaneTypeIndex;

  /// The VI's decoded `FTAB` font table, or null when absent/undecodable.
  /// Heap text runs' font ids resolve against it
  /// ([ViFontTable.entryForRunFontId]); each diagram label's resolved entry
  /// is also pre-bound onto [ViHeapObject.labelFont] at build time.
  final ViFontTable? fontTable;

  List<ViDiagram> get diagrams => [...blockDiagrams, ...frontPanelDiagrams];

  /// The bounding rectangles of the VI's objects, decoded from the `C4 2D`
  /// records (position/size of controls, nodes, decorations). Partial but real
  /// spatial structure — the seed of a read-only layout/graph view.
  List<HeapRect> get objectBounds => heapRecords.map((r) => r.bounds).whereType<HeapRect>().toList();

  /// The **labeled, positioned objects** of the VI: each pairs a `C4 2D` bounds
  /// record with the `C4 2E` label table that immediately follows it in the heap
  /// record stream. Corpus-validated association (99.8% of label tables are
  /// immediately preceded by a bounds record), but **partial**: only *labeled*
  /// objects are assembled — unlabeled decorations/nodes and wires are not — and
  /// this is not yet the full block-diagram graph.
  List<ViObject> get objects => assembleObjects(heapRecords, stringTables);

  List<String> _dedupe(Iterable<String?> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value != null && seen.add(value)) value,
    ];
  }

  /// Single-string **captions** (control names/labels) decoded from `C4 22`
  /// records — distinct from [labels] (which come from `C4 2E` string *tables*).
  /// Deduped, order-preserving.
  List<String> get captions => _dedupe([
    for (final record in heapRecords)
      if (record.kind == HeapOpcode.caption) record.text,
  ]);

  /// External **symbol / C-function names** the VI references (from `C4 C4`
  /// records in the type heap), e.g. `ps2000aRunStreaming` — the Call-Library
  /// functions this VI invokes. Deduped, order-preserving.
  List<String> get symbolNames => _dedupe([
    for (final record in heapRecords)
      if (record.kind == HeapOpcode.symbolName) record.text,
  ]);

  /// External **library/DLL paths** the VI references (from `C4 A4` `PTH0`
  /// records), e.g. `ps5000.dll`. Deduped, order-preserving.
  List<String> get paths => _dedupe([for (final record in heapRecords) record.path]);

  /// The VI's **description / help text** blocks, extracted from `C4 19` records
  /// (control tooltips, often HTML-ish). Heuristic text recovery; deduped,
  /// order-preserving.
  List<String> get descriptions => _dedupe([for (final record in heapRecords) record.descriptionText]);

  /// All distinct, deduped label strings across [stringTables], order-preserving.
  /// Convenience for "what does this VI contain".
  List<String> get labels => _dedupe(stringTables.expand((t) => t.strings));
}

/// A **named, positioned VI object** assembled from adjacent heap records: a
/// `C4 2D` bounds record immediately followed by either a `C4 22` caption or a
/// `C4 2E` string-table label.
///
/// Heuristic but corpus-validated: 99.8% of label tables and 99.4% of captions
/// sit immediately after a bounds record. Partial: represents only named/labeled
/// objects (not unlabeled nodes/wires), and is not the full block-diagram graph.
class ViObject {
  const ViObject({
    required this.sectionTag,
    required this.bounds,
    this.caption,
    this.labels = const <String>[],
  });

  final String sectionTag;

  final HeapRect bounds;

  /// The object's single caption (from a `C4 22` record), or null if it was named
  /// by a label table instead.
  final String? caption;

  /// The object's label-table strings (from a `C4 2E` record; e.g. enum items),
  /// or empty if it was named by a caption instead.
  final List<String> labels;

  String? get name => caption ?? (labels.isEmpty ? null : labels.first);
}

/// Assembles [ViObject]s by pairing each `C4 22` caption or framed `C4 2E` label
/// table with the `C4 2D` bounds record immediately preceding it (within
/// [maxRecordGap] `C4` records, same section). One bounds pairs with one name.
/// Total.
List<ViObject> assembleObjects(List<HeapRecord> records, List<HeapStringTable> stringTables, {int maxRecordGap = 3}) {
  final framed = {
    for (final table in stringTables)
      if (table.framed) '${table.sectionTag}@${table.offset}': table,
  };

  final out = <ViObject>[];
  HeapRecord? lastBounds;
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
    final inRange = lastBounds != null && idx - lastBoundsIdx <= maxRecordGap;
    if (record.kind == HeapOpcode.bounds && record.bounds != null) {
      lastBounds = record;
      lastBoundsIdx = idx;
    } else if (record.kind == HeapOpcode.caption && inRange) {
      final cap = record.text;
      if (cap != null) {
        attach(
          ViObject(
            sectionTag: record.sectionTag,
            bounds: lastBounds!.bounds!,
            caption: cap,
          ),
        );
      }
    } else if (record.kind == HeapOpcode.stringTable && inRange) {
      final table = framed['${record.sectionTag}@${record.offset + record.headerLength}'];
      if (table != null) {
        attach(
          ViObject(
            sectionTag: record.sectionTag,
            bounds: lastBounds!.bounds!,
            labels: table.strings,
          ),
        );
      }
    }
    idx++;
  }
  return out;
}

/// Builds the [ViModel] for a `.vi` — the single entry point for the read-only
/// understanding of a VI. Total: returns a model or throws [ViFormatException]
/// for a malformed container (never a `RangeError`).
ViModel buildViModel(Uint8List viBytes) =>
    buildViModelFromDecoded(decodeSections(viBytes), subViNames: readSubViNames(viBytes));

/// [buildViModel] over already-decoded sections. [subViNames] (the `LIbd`
/// dependency list) is only available from the raw container, so callers on the
/// decoded path pass it explicitly or accept an empty list.
ViModel buildViModelFromDecoded(Iterable<DecodedSection> decoded, {List<String> subViNames = const <String>[]}) {
  final list = decoded is List<DecodedSection> ? decoded : decoded.toList();
  final sections = list.map((d) => d.section).toList();
  final ver = versionFromSections(sections);
  List<ViDiagram> diagramsFor(Set<String> tags) => [
    for (final decodedSection in list)
      if (tags.contains(decodedSection.tag) && decodedSection.bytes.length >= 6)
        buildDiagram(decodedSection.bytes, sectionTag: decodedSection.tag, version: ver.version),
  ];
  final blockDiagrams = diagramsFor(const {'BDHb', 'BDHP', 'BDEx'});
  final frontPanelDiagrams = diagramsFor(const {'FPHb', 'FPHP', 'FPEx'});
  // Bind each label's first font run to its FTAB entry (see
  // [ViHeapObject.labelFont]); without a table every label keeps the
  // default face.
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
  // Pool and top-level table come from the same located VCTP section; the
  // heap's index base into that table comes from the DTHP header.
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
    connectorPaneTypeIndex: connectorPaneFromSections(sections)?.typeIndex,
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

/// LabVIEW's short on-terminal label for a resolved [type] (`DBL`, `I32`,
/// `TF`, `abc`, …), or null for kinds LabVIEW shows as art this reader does
/// not reproduce.
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
