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
/// ```
library;

import 'dart:typed_data';

import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/heap_walk.dart';
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
  Set<HeapAttribute> get attributes => const {
    HeapAttribute.borderColor,
    HeapAttribute.conNum,
    HeapAttribute.defaultData,
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

  @override
  void onAttribute(FpObject cur, HeapAttrReading attr) {
    switch (attr.attribute) {
      case HeapAttribute.stdNumMin:
        if (attr.asDouble case final value?) cur.numericRange?.min ??= value;
      case HeapAttribute.stdNumMax:
        if (attr.asDouble case final value?) cur.numericRange?.max ??= value;
      case HeapAttribute.conNum:
        cur.dataObject?.conNum ??= attr.asInt;
      case HeapAttribute.defaultData:
        if (cur.dataObject case final data? when data.defaultData == null) {
          data.defaultData = attr.flatBytes;
          data.defaultIsScalar = attr.scalarBytes != null;
        }
      case HeapAttribute.borderColor:
        cur.borderRgb ??= attr.rgb;
      case HeapAttribute.plotColor:
        final rgb = attr.rgb;
        if (cur.graph case final graph? when rgb != null) graph.plotColors = [...graph.plotColors, rgb];
      default:
        break;
    }
  }
}

/// Builds the object tree of an `FPHb` body (the section payload including its length word).
/// After the walk, label bounds are re-based on their owner, items and help text bubble up to
/// the owning control, and controls under a scrolled pane are re-anchored.
FpPanel buildFrontPanel(Uint8List body, {String? version, int sectionIndex = 0}) {
  final panel = FpPanel(objects: walkHeap(body, _FpWalk()), version: version, sectionIndex: sectionIndex);
  rebaseLabelBounds(panel);
  bubbleItemsToControls(panel);
  bubbleHelpText(panel);
  reanchorScrolledControls(panel);
  return panel;
}
