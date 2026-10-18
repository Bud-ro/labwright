/// The object tree of one front-panel heap: [FpPanel] indexes the objects by oid, parent and
/// shape, and [buildFrontPanel] fills it from an `FPHb` body through the shared heap walk with
/// the panel's own records and attributes.
///
/// Which records feed which front-panel fields, beyond the shared ones:
///
/// ```text
/// record                                   field
/// C4 plotName (0x27)                       FpGraph.plotNames
/// attributes                               FpDataObject.conNum, FpNumericControl.min and max,
///                                          borderRgb, FpGraph.plotColors
/// ```
library;

import 'dart:typed_data';

import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/heap_walk.dart';
import 'fp_object.dart';

/// The objects of one `FPHb` section, indexed by oid, parent and shape.
class FpPanel extends HeapObjectTree<FpObject> {
  FpPanel({required super.objects, super.version, super.sectionIndex}) {
    for (final object in objects) {
      switch (object) {
        case FpPlaced():
          placed.add(object);
          switch (object) {
            case FpControl():
              controls.add(object);
            case FpText():
              textLabels.add(object);
            case FpPane():
              panes.add(object);
            case FpPanelRoot() || FpContainer() || FpPart() || FpUnknownPlaced():
              break;
          }
        case FpDataObject():
          dataObjects.add(object);
        case FpRecord() || FpUnplaced():
          break;
      }
    }
  }

  /// Every object with bounds, in heap order.
  final List<FpPlaced> placed = [];

  /// The panel's data objects, one per top-level control or indicator.
  final List<FpDataObject> dataObjects = [];

  final List<FpControl> controls = [];

  final List<FpText> textLabels = [];

  final List<FpPane> panes = [];
}

class _FpScratch extends HeapScratch {
  int? conNum;
  double? numMin;
  double? numMax;
  int? borderRgb;
  List<String>? plotNames;
  List<int>? plotColors;

  FpObjectClass get objectClass => FpObjectClass.fromCode(kind);

  @override
  void reset() {
    super.reset();
    conNum = null;
    numMin = numMax = null;
    borderRgb = null;
    plotNames = null;
    plotColors = null;
  }
}

class _FpWalk extends HeapWalkListener<FpObject, _FpScratch> {
  @override
  _FpScratch createScratch() => _FpScratch();

  @override
  Set<HeapAttribute> get attributes => const {
    HeapAttribute.borderColor,
    HeapAttribute.conNum,
    HeapAttribute.plotColor,
    HeapAttribute.stdNumMax,
    HeapAttribute.stdNumMin,
  };

  @override
  void onRecord(_FpScratch cur, int opcode, Uint8List body, int start, int end) {
    if (opcode != HeapOpcode.plotName.byte || cur.objectClass != FpObjectClass.graph) return;
    final text = heapRecordText(Uint8List.sublistView(body, start, end));
    if (text != null && text.isNotEmpty) (cur.plotNames ??= []).add(text);
  }

  @override
  void onAttribute(_FpScratch cur, HeapAttrReading attr) {
    switch (attr.attribute) {
      case HeapAttribute.stdNumMin:
        cur.numMin ??= attr.asDouble;
      case HeapAttribute.stdNumMax:
        cur.numMax ??= attr.asDouble;
      case HeapAttribute.conNum:
        cur.conNum ??= attr.asInt;
      case HeapAttribute.borderColor:
        cur.borderRgb ??= attr.rgb;
      case HeapAttribute.plotColor:
        if (attr.rgb case final rgb? when cur.objectClass == FpObjectClass.graph) (cur.plotColors ??= []).add(rgb);
      default:
        break;
    }
  }

  @override
  FpObject finalize(_FpScratch s, List<FpObject> children) {
    final cls = s.objectClass;
    final bounds = s.bounds;
    final absBounds = s.absBounds;
    if (bounds == null || absBounds == null) {
      return switch (cls) {
        FpObjectClass.dco when s.typeDescIdx != null => FpDataObject(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          typeDescIdx: s.typeDescIdx!,
          conNum: s.conNum,
          typeKind: s.typeKind,
          caption: s.caption,
        ),
        FpObjectClass.root || FpObjectClass.panelRecord0101 || FpObjectClass.panelProperties => FpRecord(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          refs: s.refs,
          caption: s.caption,
        ),
        _ => FpUnplaced(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          caption: s.caption,
        ),
      };
    }
    switch (cls) {
      case FpObjectClass.panelRoot:
        return FpPanelRoot(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          caption: s.caption,
        );
      case FpObjectClass.textLabel:
        return FpText(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          caption: s.caption,
          termCount: s.termCount,
          fontRuns: s.fontRuns,
          modeWord: s.labelModeWord ?? 0,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
        );
      case FpObjectClass.graph when s.typeDescIdx != null:
        return FpGraph(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          typeDescIdx: s.typeDescIdx!,
          items: s.items,
          typeKind: s.typeKind,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          borderRgb: s.borderRgb,
          caption: s.caption,
          termCount: s.termCount,
          plotNames: s.plotNames ?? const [],
          plotColors: s.plotColors ?? const [],
        );
      case FpObjectClass.numeric || FpObjectClass.enumRing when s.typeDescIdx != null:
        return FpNumericControl(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          typeDescIdx: s.typeDescIdx!,
          items: s.items,
          typeKind: s.typeKind,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          borderRgb: s.borderRgb,
          caption: s.caption,
          termCount: s.termCount,
          min: s.numMin,
          max: s.numMax,
        );
      default:
        break;
    }
    switch (cls.category) {
      case FpObjectKind.pane:
        return FpPane(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          caption: s.caption,
          termCount: s.termCount,
        );
      case FpObjectKind.control when s.typeDescIdx != null:
        return FpControl(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          typeDescIdx: s.typeDescIdx!,
          items: s.items,
          typeKind: s.typeKind,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          borderRgb: s.borderRgb,
          caption: s.caption,
          termCount: s.termCount,
        );
      case FpObjectKind.container when s.typeDescIdx != null:
        return FpContainer(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          caption: s.caption,
          termCount: s.termCount,
          typeDescIdx: s.typeDescIdx!,
          typeKind: s.typeKind,
        );
      case FpObjectKind.part || FpObjectKind.terminalCluster when s.typeDescIdx != null:
        return FpTypedPart(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          caption: s.caption,
          termCount: s.termCount,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          borderRgb: s.borderRgb,
          displayFormat: s.displayFormat,
          items: s.items,
          fontRuns: s.fontRuns,
          typeDescIdx: s.typeDescIdx!,
          typeKind: s.typeKind,
        );
      case FpObjectKind.part || FpObjectKind.container || FpObjectKind.control || FpObjectKind.terminalCluster:
        return FpPart(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          borderRgb: s.borderRgb,
          displayFormat: s.displayFormat,
          items: s.items,
          caption: s.caption,
          termCount: s.termCount,
          fontRuns: s.fontRuns,
          typeKind: s.typeKind,
        );
      case FpObjectKind.root || FpObjectKind.unknown:
        return FpUnknownPlaced(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bounds: bounds,
          boundsOffset: s.boundsOffset,
          absBounds: absBounds,
          caption: s.caption,
          termCount: s.termCount,
        );
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
