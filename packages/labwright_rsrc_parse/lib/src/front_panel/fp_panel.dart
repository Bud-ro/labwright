/// The object tree of one front-panel heap: [FpPanel] indexes the objects by oid and parent,
/// and [buildFrontPanel] fills it from an `FPHb` body through the shared heap walk with the
/// panel's own records and attributes.
///
/// Which records feed which front-panel fields, beyond the shared ones:
///
/// ```text
/// record                                   field
/// C4 plotName (0x27)                       FpGraph.plotNames
/// attributes                               FpDataObject.conNum, FpNumericRange.min and max,
///                                          borderRgb, FpGraph.plotColors
/// array index group                        arrayIndex
/// ```
library;

import 'dart:typed_data';

import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/heap_walk.dart';
import '../heap/obj_flags.dart';
import 'fp_object.dart';

/// The objects of one `FPHb` section, indexed by oid and parent.
class FpPanel extends HeapObjectTree<FpObject> {
  FpPanel({required super.objects, super.version, super.sectionIndex});

  /// The panel's top-level controls and indicators: the data objects with a type index.
  List<FpObject> get controls => [
    for (final object in objects)
      if (object.dataObject != null && object.typeDescIdx != null) object,
  ];
}

class _FpWalk extends HeapWalkListener<FpObject> {
  @override
  FpObject createObject({required int oid, required int kind, required int offset}) =>
      FpObject(oid: oid, kind: kind, offset: offset);

  @override
  HeapGroupCapture<FpObject>? captureGroup(FpObject owner, int tag) =>
      tag == HeapGroupTag.arrayIndex.tag && owner.objectClass == FpObjectClass.array ? ArrayIndexCapture(owner) : null;

  @override
  Set<HeapAttribute> get attributes => const {
    HeapAttribute.borderColor,
    HeapAttribute.conNum,
    HeapAttribute.cosmColorB,
    HeapAttribute.plotColor,
    HeapAttribute.stdNumMax,
    HeapAttribute.stdNumMin,
  };

  @override
  void onRecord(FpObject cur, int opcode, Uint8List body, int start, int end) {
    if (opcode != HeapOpcode.plotName.byte) return;
    final graph = cur.graph;
    if (graph == null) return;
    final text = heapRecordText(Uint8List.sublistView(body, start, end));
    if (text != null && text.isNotEmpty) graph.plotNames = [...graph.plotNames, text];
  }

  void _plotColor(FpObject cur, int? rgb) {
    final graph = cur.graph;
    if (graph == null || rgb == null) return;
    graph.plotColors = [...graph.plotColors, rgb];
  }

  @override
  void onScalarAttribute(FpObject cur, HeapAttribute attribute, int value, int scalarBytes) {
    switch (attribute) {
      case HeapAttribute.cosmColorB:
        if (cur.isTextLabel) cur.labelModeWord ??= value;
      case HeapAttribute.conNum:
        cur.dataObject?.conNum ??= value;
      case HeapAttribute.borderColor:
        cur.borderRgb ??= heapScalarColorRgb(value);
      case HeapAttribute.plotColor:
        _plotColor(cur, heapScalarColorRgb(value));
      default:
        break;
    }
  }

  @override
  void onAttribute(FpObject cur, HeapAttr attr) {
    switch (attr.attribute) {
      case HeapAttribute.stdNumMin:
        if (cur.numericRange case final range? when attr.asDouble != null) range.min ??= attr.asDouble;
      case HeapAttribute.stdNumMax:
        if (cur.numericRange case final range? when attr.asDouble != null) range.max ??= attr.asDouble;
      case HeapAttribute.cosmColorB:
        if (cur.isTextLabel) cur.labelModeWord ??= attr.asInt;
      case HeapAttribute.borderColor:
        cur.borderRgb ??= heapAttrColorRgb(attr);
      case HeapAttribute.plotColor:
        _plotColor(cur, heapAttrColorRgb(attr));
      default:
        break;
    }
  }
}

/// Builds the object tree of an `FPHb` body (the section payload including its length word).
/// After the walk, label bounds are re-based on their owner, objects with size records become
/// terminal clusters, data objects learn whether they are indicators, items and help text
/// bubble up to the owning control, and controls under a scrolled pane are re-anchored.
FpPanel buildFrontPanel(Uint8List body, {String? version, int sectionIndex = 0}) {
  final panel = FpPanel(objects: walkHeap(body, _FpWalk()), version: version, sectionIndex: sectionIndex);
  rebaseLabelBounds(panel);
  for (final object in panel.objects) {
    if (object.objectClass == FpObjectClass.terminalCluster || object.termCount >= 1) {
      object.category = FpObjectKind.terminalCluster;
    }
    object.dataObject?.isIndicator = object.hasFlag(ViObjFlag.indicator);
  }
  bubbleItemsToControls(panel, isControl: (o) => o.objectClass.isControlTerminal);
  bubbleHelpText(panel);
  reanchorScrolledControls(
    panel,
    isPane: (o) => o.objectClass == FpObjectClass.pane,
    isControl: (o) => o.objectClass.isControlTerminal,
  );
  return panel;
}
