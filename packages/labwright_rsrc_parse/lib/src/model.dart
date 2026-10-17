import 'dart:typed_data';

import '../labwright_rsrc_parse.dart';

/// Everything decoded from one VI that the inspector and transpiler consume: the version and
/// title, per-block component totals, the block diagrams and front panels, the type pool, the
/// sub-VI names, the connector-pane type and the font table; and the sections themselves,
/// which edits change and [serialize] writes back into the file they were loaded from.
class ViModel {
  ViModel({
    required this.version,
    required this.title,
    required this.components,
    this.sections = const <ViSectionBuffer>[],
    Uint8List? file,
    this.blockDiagrams = const <BdDiagram>[],
    this.frontPanels = const <FpPanel>[],
    this.subViNames = const <String>[],
    this.types = const <ViType>[],
    this.connectorPaneType,
    this.paneTerminals = const <FpObject?>[],
    this.fontTable,
  }) : _fileBytes = file {
    for (final section in sections) {
      section.onEdit = _record;
    }
  }

  /// The version string from `vers`.
  final String? version;

  /// The title from `vers`.
  final String? title;

  final List<BlockComponent> components;

  /// The file's own sections, in file order, each holding its inflated payload.
  final List<ViSectionBuffer> sections;

  final Uint8List? _fileBytes;

  ViVi? _file;

  /// The container the sections were loaded from, parsed when first needed; null for a model
  /// built without a file.
  ViVi? get file => _fileBytes == null ? null : _file ??= ViVi.parse(_fileBytes);

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
    final muid = section(BlockTag.muid.tag)!;
    final uid = ViMaxUid(muid.bytes).maxUid + 1;
    muid.edit((bytes) => ViMaxUid(bytes).maxUid = uid);
    return uid;
  }

  /// The edits made so far, newest last, grouped as [transact] grouped them; an operation
  /// outside a transaction is a group of its own.
  final List<List<ViSectionEdit>> journal = [];

  List<ViSectionEdit>? _open;

  bool _recordsEdits = true;

  /// Runs [body] as one group of edits, which [undo] takes back together.
  T transact<T>(T Function() body) {
    if (_open != null) return body();
    final group = _open = <ViSectionEdit>[];
    try {
      return body();
    } finally {
      _open = null;
      if (group.isNotEmpty) journal.add(group);
    }
  }

  void _record(ViSectionEdit edit) {
    if (!_recordsEdits) return;
    (_open ?? (journal..add([])).last).add(edit);
  }

  /// Takes back the newest group of edits, byte for byte, and rebuilds what those sections
  /// decide: a heap's tree after the heap, the types after `VCTP` or a heap. False when there
  /// is nothing to undo.
  bool undo() {
    if (journal.isEmpty) return false;
    final group = journal.removeLast();
    _recordsEdits = false;
    for (final edit in group.reversed) {
      edit.section.splice(edit.start, edit.start + edit.inserted, edit.removed);
    }
    _recordsEdits = true;
    final touched = {for (final edit in group) edit.section};
    for (final section in touched) {
      for (final diagram in List.of(blockDiagrams)) {
        if (section.tag == BlockTag.bdhb.tag && section.index == diagram.sectionIndex) reloadHeap(diagram);
      }
      for (final panel in List.of(frontPanels)) {
        if (section.tag == BlockTag.fphb.tag && section.index == panel.sectionIndex) reloadHeap(panel);
      }
    }
    if (touched.any((s) => s.tag == BlockTag.vctp.tag)) reloadTypes();
    return true;
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
  final List<BdDiagram> blockDiagrams;

  /// One panel per `FPHb` section.
  final List<FpPanel> frontPanels;

  BdDiagram? get primaryBlockDiagram => largestHeap(blockDiagrams);

  /// Sub-VI names recovered from `LIbd`, see [readSubViNames].
  final List<String> subViNames;

  /// The `VCTP` type pool.
  List<ViType> types;

  /// The VI's call signature from `CONP`: one parameter per pane terminal; null without `CONP`.
  ViType? connectorPaneType;

  /// The panel control behind each connector-pane terminal, in pane order; null where the
  /// terminal is unwired or no control answers for it. See [connectorPaneTerminals].
  List<FpObject?> paneTerminals;

  /// Appends [descriptor] to the type pool and returns its index.
  int addType(Uint8List descriptor) {
    final vctp = section(BlockTag.vctp.tag)!;
    final pool = ViTypePool(vctp.bytes);
    final index = pool.length;
    transact(() {
      vctp.splice(pool.descriptorsEnd, pool.descriptorsEnd, descriptor);
      vctp.edit((bytes) => ViTypePool.count.write(ByteData.sublistView(bytes), index + 1));
    });
    reloadTypes();
    return index;
  }

  /// Replaces the descriptor at [index] with [descriptor].
  void replaceType(int index, Uint8List descriptor) {
    final type = types[index];
    transact(() => section(BlockTag.vctp.tag)!.splice(type.offset, type.end, descriptor));
    reloadTypes();
  }

  /// Makes [indices] the pool's top-level types, in that order.
  void setTopLevelTypes(List<int> indices) {
    final vctp = section(BlockTag.vctp.tag)!;
    final pool = ViTypePool(vctp.bytes);
    transact(
      () => vctp.splice(pool.descriptorsEnd, vctp.length, [
        indices.length >> 8 & 0xff,
        indices.length & 0xff,
        for (final index in indices) ...[index >> 8 & 0xff, index & 0xff],
      ]),
    );
    reloadTypes();
  }

  /// The heap section [heap] was built from.
  ViSectionBuffer sectionOf(HeapObjectTree heap) => section(_tagOf(heap).tag, heap.sectionIndex)!;

  static BlockTag _tagOf(HeapObjectTree heap) => switch (heap) {
    BdDiagram() => BlockTag.bdhb,
    FpPanel() => BlockTag.fphb,
    _ => throw ArgumentError.value(heap, 'heap', 'not a diagram or panel'),
  };

  /// Moves [object] by ([dx], [dy]): its bounds record is rewritten in place, and the absolute
  /// bounds of everything inside it follow.
  void moveObject<T extends HeapObject>(HeapObjectTree<T> heap, T object, {required int dx, required int dy}) {
    final at = object.boundsOffset;
    final bounds = object.bounds;
    if (at == null || bounds == null) throw ArgumentError('object ${object.oid} has no bounds record');
    final moved = HeapRect(
      top: bounds.top + dy,
      left: bounds.left + dx,
      bottom: bounds.bottom + dy,
      right: bounds.right + dx,
    );
    final payload = Uint8List(8);
    ByteData.sublistView(payload)
      ..setInt16(0, moved.top)
      ..setInt16(2, moved.left)
      ..setInt16(4, moved.bottom)
      ..setInt16(6, moved.right);
    transact(() => sectionOf(heap).write(at, payload));
    object.bounds = moved;
    void follow(T inner) {
      if (inner.absBounds case final abs?) {
        inner.absBounds = HeapRect(
          top: abs.top + dy,
          left: abs.left + dx,
          bottom: abs.bottom + dy,
          right: abs.right + dx,
        );
      }
      for (final child in heap.childrenOf(inner)) {
        follow(child);
      }
    }

    follow(object);
  }

  /// Gives [object] the label [text], written as its code units in place of its label record.
  void setLabel<T extends HeapObject>(HeapObjectTree<T> heap, T object, String text) {
    final at = object.labelOffset;
    if (at == null) throw ArgumentError('object ${object.oid} has no label record');
    final record = encodeHeapC4Record(HeapOpcode.caption.byte, text.codeUnits);
    transact(() => sectionOf(heap).splice(at, at + object.labelLength, record));
    final delta = record.length - object.labelLength;
    final named = heap.parentOf(object);
    if (named != null && named.labelOffset == null && named.label == object.label?.trim()) named.label = text.trim();
    object
      ..label = text
      ..labelLength = record.length;
    _shiftHeap(heap, at, delta);
  }

  /// Duplicates [object] with everything inside it right after it, every object in the copy
  /// under a fresh id and the references between them following, widened where a fresh id
  /// needs it. The heap's tree is rebuilt; the result is that tree and the copy.
  ({H heap, T clone}) cloneObject<H extends HeapObjectTree<T>, T extends HeapObject>(H heap, T object) {
    final section = sectionOf(heap);
    final body = section.bytes;
    final view = ByteData.sublistView(body);
    final ids = <int, int>{};
    final rebuilt = transact(() {
      for (var at = object.offset; at < object.end; at += recordSkip(body, at)!) {
        final header = isHeapObjectHeaderLead(body[at]) ? heapObjectHeaderLength(body, at) : 0;
        if (header != 0) ids[heapObjectHeaderOid(body, at, header)] = allocateUid();
      }
      final copy = BytesBuilder(copy: false);
      for (var at = object.offset; at < object.end;) {
        final step = recordSkip(body, at)!;
        final lead = body[at];
        final header = isHeapObjectHeaderLead(lead) ? heapObjectHeaderLength(body, at) : 0;
        final ref = header != 0 ? null : decodeHeapRefIn(view, body, at);
        final target = ref == null ? null : ids[ref.targetOid];
        if (header != 0) {
          final fresh = ids[heapObjectHeaderOid(body, at, header)]!;
          copy.add(encodeHeapObjectHeader(lead, body[at + 1], heapObjectHeaderKind(body, at), fresh));
        } else if (target != null) {
          copy.add(encodeHeapRef(lead, body[at + 1], target));
        } else {
          copy.add(Uint8List.sublistView(body, at, at + step));
        }
        at += step;
      }
      section.splice(object.end, object.end, copy.takeBytes());
      return reloadHeap(heap);
    });
    return (heap: rebuilt, clone: rebuilt.byId[ids[object.oid]!]!);
  }

  /// Rebuilds [heap] from its section, in its place among the model's diagrams or panels, with
  /// the fonts and types resolved again.
  H reloadHeap<H extends HeapObjectTree>(H heap) {
    final section = sectionOf(heap);
    final H rebuilt;
    switch (heap) {
      case BdDiagram():
        final diagram = buildBlockDiagram(section.bytes, version: heap.version, sectionIndex: heap.sectionIndex);
        blockDiagrams[blockDiagrams.indexOf(heap)] = diagram;
        rebuilt = diagram as H;
      case FpPanel():
        final panel = buildFrontPanel(section.bytes, version: heap.version, sectionIndex: heap.sectionIndex);
        frontPanels[frontPanels.indexOf(heap)] = panel;
        rebuilt = panel as H;
      default:
        throw ArgumentError.value(heap, 'heap', 'not a diagram or panel');
    }
    if (fontTable case final fonts?) _resolveFonts(rebuilt, fonts);
    reloadTypes();
    return rebuilt;
  }

  /// Moves every heap offset after [at] by [delta], after a splice there.
  void _shiftHeap(HeapObjectTree heap, int at, int delta) {
    if (delta == 0) return;
    for (final object in heap.objects) {
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
    for (final heap in <HeapObjectTree>[...blockDiagrams, ...frontPanels]) {
      for (final object in heap.objects) {
        object.resolvedType = null;
      }
    }
    final dataSpace = ViDataSpaceTypes(
      pool: types,
      table: pool?.topLevelIndices ?? const [],
      typeIndexBase: switch (section(BlockTag.dthp.tag)) {
        final dthp? => switch (ViDataTypeHeap(dthp.bytes)) {
          ViDataTypeHeapCompact(:final viTypeIndexBase) => viTypeIndexBase,
          _ => null,
        },
        null => null,
      },
    );
    resolvePanelTypes(frontPanels, dataSpace);
    resolveDiagramTypes(blockDiagrams, frontPanels, dataSpace);
    connectorPaneType = switch (section(BlockTag.conp.tag)) {
      final conp? => ViConnectorPane(conp.bytes).typeIn(pool),
      null => null,
    };
    paneTerminals = connectorPaneTerminals(
      paneType: connectorPaneType,
      panels: frontPanels,
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
}

void _resolveFonts(HeapObjectTree heap, ViFontTable fonts) {
  for (final object in heap.objects) {
    if (object.textStyleRuns.isEmpty) continue;
    object.labelFont = fonts.entryForRunFontId(object.textStyleRuns.first.fontId);
  }
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
  Iterable<DecodedSection> heapsOf(BlockTag heap) => list.where((s) => s.tag == heap.tag && s.bytes.length >= 6);
  final blockDiagrams = [
    for (final s in heapsOf(BlockTag.bdhb)) buildBlockDiagram(s.bytes, version: ver.version, sectionIndex: s.index),
  ];
  final frontPanels = [
    for (final s in heapsOf(BlockTag.fphb)) buildFrontPanel(s.bytes, version: ver.version, sectionIndex: s.index),
  ];
  final ftab = list.where((s) => s.tag == 'FTAB').map((s) => s.bytes).firstOrNull;
  final fontTable = ftab == null ? null : ViFontTable(ftab);
  if (fontTable != null) {
    for (final heap in <HeapObjectTree>[...blockDiagrams, ...frontPanels]) {
      _resolveFonts(heap, fontTable);
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
    file: file,
    subViNames: subViNames,
    fontTable: fontTable,
    version: ver.version,
    title: ver.title,
    components: componentsFromDecoded(list),
    blockDiagrams: blockDiagrams,
    frontPanels: frontPanels,
  )..reloadTypes();
}

/// The heap with the most placed objects, or null when none has any.
H? largestHeap<H extends HeapObjectTree>(List<H> heaps) {
  H? best;
  var bestCount = 0;
  for (final heap in heaps) {
    var count = 0;
    for (final object in heap.objects) {
      if (object.absBounds != null) count++;
    }
    if (count > bestCount) {
      best = heap;
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
