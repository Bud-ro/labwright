/// Builds a [BdDiagram] from a `BDHb` body: [buildBlockDiagram] runs the shared heap walk
/// with the block diagram's own records and attributes, shapes each object as its class and
/// records call for, then runs the passes that depend on the finished tree.
/// [decodeBdConstValues] runs once the data-space join has resolved each constant's type.
///
/// Which records feed which block-diagram fields, beyond the shared ones:
///
/// ```text
/// record                                   field
/// C4 path (0xa4), symbolName (0xc4)        BdForeignCall.libraryPath, entryPoint
/// attributes                               BdConstant.raw and text, BdTerminal.termBounds and
///                                          termBmp, BdPrimitive.primResId,
///                                          BdMultiFrameStructure.dIdx, BdSignal.wireTableRaw
///                                          and lastSignalKind, BdCaseStructure.defaultFrameIndex,
///                                          BdStructure.structRgb
/// case selector groups                     BdCaseStructure.selectorRanges, selectorStrings
/// array index group                        BdContainer.arrayIndex
/// ```
library;

import 'dart:typed_data';

import '../blocks/VCTP_type_pool.dart';
import '../heap/heap.dart';
import '../heap/heap_object.dart';
import '../heap/heap_walk.dart';
import 'bd_diagram.dart';
import 'bd_object.dart';

const int _structureAreaCap = 20000;

int _signedAtWidth(int value, HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.u8 => value.toSigned(8),
  HeapAttrWidth.u16 => value.toSigned(16),
  HeapAttrWidth.u24 => value.toSigned(24),
  HeapAttrWidth.rgb => value.toSigned(32),
  _ => value,
};

String? _selectorPoolString(Uint8List body, int offset, int lead, int span) {
  if (lead == kHeapRecordPrefix) {
    if (offset + 3 > body.length) return null;
    final count = body[offset + 2];
    if (3 + count > span || offset + 3 + count > body.length) return null;
    return String.fromCharCodes(body.sublist(offset + 3, offset + 3 + count));
  }
  final attr = decodeHeapAttr(body, offset);
  final value = attr?.asInt;
  if (attr == null || value == null) return null;
  final bytes = heapAttrScalarBytes(attr.width) ?? 0;
  final chars = [for (var i = bytes - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];
  return String.fromCharCodes(chars.skipWhile((char) => char == 0));
}

class _BdScratch extends HeapScratch {
  Uint8List? constRaw;
  bool constScalar = false;
  String? constText;
  HeapRect? termBounds;
  int? termBmp;
  int? primResId;
  int? dIdx;
  Uint8List? wireTableRaw;
  int? lastSignalKind;
  int? defaultFrameIndex;
  int? structRgb;
  String? libraryPath;
  String? entryPoint;
  List<ViSelectorRange>? selectorRanges;
  List<String>? selectorStrings;

  BdObjectClass get objectClass => BdObjectClass.fromCode(kind);

  @override
  void reset() {
    super.reset();
    constRaw = null;
    constScalar = false;
    constText = null;
    termBounds = null;
    termBmp = null;
    primResId = null;
    dIdx = null;
    wireTableRaw = null;
    lastSignalKind = null;
    defaultFrameIndex = null;
    structRgb = null;
    libraryPath = null;
    entryPoint = null;
    selectorRanges = null;
    selectorStrings = null;
  }
}

/// A case structure's selector range list or string pool.
class _SelectorCapture extends HeapGroupCapture {
  _SelectorCapture(_BdScratch super.owner, {required this.inPool});

  final bool inPool;
  final List<ViSelectorRange> _ranges = [];
  final List<String> _strings = [];
  bool _entryOpen = false;
  int _low = 0, _high = 0, _lowBound = 0, _highBound = 0, _frame = 0;

  @override
  void openGroup(int tag) {
    if (tag == HeapGroupTag.selectorRange.tag && depth == 2 && !inPool) {
      _entryOpen = true;
      _low = _high = _lowBound = _highBound = _frame = 0;
    }
  }

  @override
  void closeGroup() {
    if (_entryOpen && depth == 1) {
      _ranges.add(
        ViSelectorRange(
          low: _low,
          high: _high,
          lowBound: ViSelectorBound.ofCode(_lowBound),
          highBound: ViSelectorBound.ofCode(_highBound),
          frame: _frame,
        ),
      );
      _entryOpen = false;
    }
    if (depth != 0) return;
    final scratch = owner as _BdScratch;
    if (inPool) {
      scratch.selectorStrings ??= _strings;
    } else {
      scratch.selectorRanges ??= _ranges;
    }
  }

  @override
  bool record(Uint8List body, ByteData view, int offset, int lead, int length) {
    if (inPool) {
      final value = _selectorPoolString(body, offset, lead, length);
      if (value == null) return false;
      _strings.add(value);
      return true;
    }
    if (!_entryOpen) return false;
    final attr = decodeHeapAttrIn(view, body, offset);
    final value = attr?.asInt;
    if (attr == null || value == null) return false;
    final tag = attr.rawTag;
    if (tag == SelectorRangeAttr.low.raw) {
      _low = _signedAtWidth(value, attr.width);
    } else if (tag == SelectorRangeAttr.high.raw) {
      _high = _signedAtWidth(value, attr.width);
    } else if (tag == SelectorRangeAttr.lowBound.raw) {
      _lowBound = value;
    } else if (tag == SelectorRangeAttr.highBound.raw) {
      _highBound = value;
    } else if (tag == SelectorRangeAttr.frame.raw) {
      _frame = value;
    } else {
      return false;
    }
    return true;
  }
}

class _BdWalk extends HeapWalkListener<BdObject, _BdScratch> {
  @override
  _BdScratch createScratch() => _BdScratch();

  @override
  HeapGroupCapture? captureGroup(_BdScratch owner, int tag) {
    if (owner.objectClass == BdObjectClass.caseStructure && kViSelectorGroupTags.contains(tag)) {
      return _SelectorCapture(owner, inPool: tag == HeapGroupTag.selectorStringPool.tag);
    }
    if (tag == HeapGroupTag.arrayIndex.tag && owner.objectClass == BdObjectClass.array) {
      return ArrayIndexCapture(owner);
    }
    return null;
  }

  @override
  Set<HeapAttribute> get attributes => const {
    HeapAttribute.compressedWireTable,
    HeapAttribute.constValue,
    HeapAttribute.dIdx,
    HeapAttribute.lastSignalKind,
    HeapAttribute.primResID,
    HeapAttribute.selectDefaultCase,
    HeapAttribute.structColor,
    HeapAttribute.termBMPs,
    HeapAttribute.termBounds,
  };

  @override
  void onRecord(_BdScratch cur, int opcode, Uint8List body, int start, int end) {
    if (cur.objectClass != BdObjectClass.callLibrary) return;
    if (opcode == HeapOpcode.path.byte) {
      cur.libraryPath ??= heapRecordPath(Uint8List.sublistView(body, start, end));
    } else if (opcode == HeapOpcode.symbolName.byte) {
      cur.entryPoint ??= heapRecordText(Uint8List.sublistView(body, start, end));
    }
  }

  @override
  void onAttribute(_BdScratch cur, HeapAttrReading attr) {
    switch (attr.attribute) {
      case HeapAttribute.constValue:
        if (cur.objectClass != BdObjectClass.constant) return;
        if (attr.asString case final text? when text.isNotEmpty) cur.constText ??= text;
        if (cur.constRaw == null) {
          cur.constRaw = attr.flatBytes;
          cur.constScalar = attr.scalarBytes != null;
        }
      case HeapAttribute.termBounds:
        cur.termBounds ??= attr.asRect;
      case HeapAttribute.termBMPs:
        cur.termBmp ??= attr.asInt;
      case HeapAttribute.primResID:
        if (cur.objectClass == BdObjectClass.primitive && attr.scalarBytes == 2) cur.primResId ??= attr.asInt;
      case HeapAttribute.dIdx:
        if (cur.objectClass.isMultiFrameStructure) cur.dIdx ??= attr.asInt;
      case HeapAttribute.compressedWireTable:
        if (cur.objectClass == BdObjectClass.signal) cur.wireTableRaw ??= attr.flatBytes;
      case HeapAttribute.selectDefaultCase:
        final frame = attr.asInt;
        if (cur.objectClass == BdObjectClass.caseStructure && frame != null && frame != kViNoDefaultFrame) {
          cur.defaultFrameIndex ??= frame;
        }
      case HeapAttribute.lastSignalKind:
        final word = attr.asInt;
        if (cur.objectClass == BdObjectClass.signal && word != null && word <= 0xffff) cur.lastSignalKind ??= word;
      case HeapAttribute.structColor:
        cur.structRgb ??= attr.rgb;
      default:
        break;
    }
  }

  @override
  BdObject finalize(_BdScratch s, List<BdObject> children) {
    final cls = s.objectClass;
    final bounds = s.bounds;
    final absBounds = s.absBounds;
    if (bounds == null || absBounds == null) {
      return switch (cls) {
        BdObjectClass.root => BdRoot(oid: s.oid, kind: s.kind, offset: s.offset, end: s.end, refs: s.refs),
        BdObjectClass.frame => BdFrame(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          caption: s.caption,
        ),
        BdObjectClass.signal => BdSignal(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          endpoints: s.refs,
          wireTableRaw: s.wireTableRaw,
          lastSignalKind: s.lastSignalKind,
          caption: s.caption,
        ),
        BdObjectClass.terminalHolder => BdTerminalHolder(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          dcoRef: s.dcoRefs?.firstOrNull,
          caption: s.caption,
        ),
        BdObjectClass.constant when s.typeDescIdx != null => BdConstant(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          refs: s.refs,
          helpText: s.helpText,
          typeDescIdx: s.typeDescIdx!,
          raw: s.constRaw,
          scalar: s.constScalar,
          text: s.constText,
          typeKind: s.typeKind,
          caption: s.caption,
        ),
        BdObjectClass.tunnelIndexer when s.typeDescIdx != null => BdTunnelIndexer(
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          typeDescIdx: s.typeDescIdx!,
          typeKind: s.typeKind,
          caption: s.caption,
        ),
        BdObjectClass.formulaNodeTerminal ||
        BdObjectClass.matlabScriptTerminal when s.termBounds != null && s.typeDescIdx != null => BdScriptTerminal(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          termBounds: s.termBounds!,
          typeDescIdx: s.typeDescIdx!,
          termBmp: s.termBmp,
          caption: s.caption,
          typeKind: s.typeKind,
          fontRuns: s.fontRuns,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
        ),
        _ when s.termBounds != null && s.typeDescIdx != null => BdTerminal(
          cls,
          oid: s.oid,
          kind: s.kind,
          offset: s.offset,
          end: s.end,
          parentOid: s.parentOid,
          objFlags: s.objFlags ?? 0,
          helpText: s.helpText,
          refs: s.refs,
          termBounds: s.termBounds!,
          typeDescIdx: s.typeDescIdx!,
          termBmp: s.termBmp,
          caption: s.caption,
          typeKind: s.typeKind,
        ),
        _ => BdUnplaced(
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
      case BdObjectClass.primitive when s.primResId != null:
        return BdPrimitive(
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
          primResId: s.primResId!,
        );
      case BdObjectClass.formulaNode || BdObjectClass.matlabScriptNode:
        return BdScriptNode(
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
          typeKind: s.typeKind,
          fontRuns: s.fontRuns,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
        );
      case BdObjectClass.callLibrary:
        return BdForeignCall(
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
          typeKind: s.typeKind,
          libraryPath: s.libraryPath,
          entryPoint: s.entryPoint,
        );
      case BdObjectClass.caseStructure:
        return BdCaseStructure(
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
          structRgb: s.structRgb,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          dIdx: s.dIdx,
          selectorRanges: s.selectorRanges ?? const [],
          selectorStrings: s.selectorStrings ?? const [],
          defaultFrameIndex: s.defaultFrameIndex,
        );
      case BdObjectClass.disableStructure || BdObjectClass.eventStructure || BdObjectClass.stackedSequence:
        return BdMultiFrameStructure(
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
          structRgb: s.structRgb,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
          dIdx: s.dIdx,
        );
      case BdObjectClass.cluster || BdObjectClass.array || BdObjectClass.typeDefinition when s.typeDescIdx != null:
        return BdContainer(
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
          arrayIndex: s.arrayIndex,
          typeKind: s.typeKind,
        );
      case BdObjectClass.pane:
        return BdPane(
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
      case BdObjectClass.wire:
        return BdWire(
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
      case BdObjectClass.panelTerminal when s.dcoRefs?.firstOrNull != null:
        return BdPanelTerminal(
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
          dcoRef: s.dcoRefs!.first,
          typeKind: s.typeKind,
        );
      case BdObjectClass.textLabel || BdObjectClass.caseSelectorLabel:
        return BdText(
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
          fontRuns: s.fontRuns,
          modeWord: cls == BdObjectClass.textLabel ? s.labelModeWord ?? 0 : 0,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
        );
      case BdObjectClass.numericDisplay:
        return BdNumericDisplay(
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
          displayFormat: s.displayFormat,
          fontRuns: s.fontRuns,
          typeKind: s.typeKind,
        );
      case BdObjectClass.itemList:
        return BdItemList(
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
          items: s.items,
          fontRuns: s.fontRuns,
          typeKind: s.typeKind,
        );
      default:
        break;
    }
    switch (cls.category) {
      case BdObjectKind.node:
        return BdNode(
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
          typeKind: s.typeKind,
        );
      case BdObjectKind.structure:
        return BdStructure(
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
          structRgb: s.structRgb,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
        );
      case BdObjectKind.terminal || BdObjectKind.unknown when s.typeDescIdx != null:
        return BdControlBody(
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
          items: s.items,
          typeKind: s.typeKind,
          bgRgb: s.bgRgb,
          fgRgb: s.fgRgb,
          contentRgb: s.contentRgb,
        );
      case BdObjectKind.terminal || BdObjectKind.decoration || BdObjectKind.terminalCluster:
        return BdPart(
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
          typeKind: s.typeKind,
        );
      case BdObjectKind.unknown when _looksLikeNode(s, children):
        return BdNode(
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
          typeKind: s.typeKind,
        );
      case BdObjectKind.unknown || BdObjectKind.frame || BdObjectKind.wire:
        return BdUnknownPlaced(
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

/// Whether a placed object of an unknown class sits in a frame, is node-sized and holds
/// terminal holders but no connector terminal, so it is drawn as a node.
bool _looksLikeNode(_BdScratch s, List<BdObject> children) {
  final bounds = s.absBounds!;
  if (bounds.width <= 0 || bounds.height <= 0 || bounds.width * bounds.height >= _structureAreaCap) return false;
  if (children.isEmpty || BdObjectClass.fromCode(s.parentKind ?? -1) != BdObjectClass.frame) return false;
  return children.any((c) => c is BdTerminalHolder) &&
      !children.any((c) => c.objectClass == BdObjectClass.connectorTerminal);
}

/// Builds the object tree of a `BDHb` body (the section payload including its length word).
/// After the walk, label bounds are re-based on their owner, flat-sequence frames are shifted
/// to their declared offsets, items and help text bubble up to the owning control, unlabelled
/// nodes take their first child label, and controls under a scrolled viewport are re-anchored.
BdDiagram buildBlockDiagram(Uint8List body, {String? version, int sectionIndex = 0}) {
  final diagram = BdDiagram(objects: walkHeap(body, _BdWalk()), version: version, sectionIndex: sectionIndex);
  rebaseLabelBounds(diagram);
  _shiftFlatSequenceFrames(diagram);
  bubbleItemsToControls(diagram);
  bubbleHelpText(diagram);
  _labelNodesFromChildren(diagram);
  reanchorScrolledControls(diagram);
  return diagram;
}

void _shiftFlatSequenceFrames(BdDiagram diagram) {
  for (final object in diagram.structures) {
    if (object.objectClass != BdObjectClass.flatSequence) continue;
    for (final frame in diagram.childrenOf(object)) {
      if (frame is! BdStructure || frame.objectClass != BdObjectClass.sequenceFrame) continue;
      final local = frame.bounds, abs = frame.absBounds, owner = object.absBounds;
      shiftSubtree(diagram, frame, dTop: owner.top + local.top - abs.top, dLeft: owner.left + local.left - abs.left);
    }
  }
}

void _labelNodesFromChildren(BdDiagram diagram) {
  for (final node in diagram.nodes) {
    if (node.caption != null) continue;
    for (final child in diagram.childrenOf(node)) {
      final text = child is BdText ? child.caption?.text.trim() : null;
      if (text != null && text.isNotEmpty) {
        node.caption = HeapCaption(text);
        break;
      }
    }
  }
}

const int _intCertainCeil = 0x800000;

const double _dblWindowFloor = 1e-12, _dblWindowCeil = 1e12;

const Set<int> _zeroPayloadLengths = {5, 9};

// TODO: absolute (type 0) and UNC (type 2) path text is not decoded.
/// The segments of a flat relative `PTH0` path joined with backslashes; null for any other
/// path form.
String? decodeFlatPathText(Uint8List? raw) {
  if (raw == null || raw.length < 12) return null;
  if (raw[0] != 0x50 || raw[1] != 0x54 || raw[2] != 0x48 || raw[3] != 0x30) {
    return null;
  }
  final view = ByteData.sublistView(raw);
  final contentLength = view.getUint32(4);
  final end = 8 + contentLength;
  if (end > raw.length) return null;
  final pathType = view.getUint16(8);
  final count = view.getUint16(10);
  if (pathType != 1 || count < 1) return null;
  var offset = 12;
  final segments = <String>[];
  for (var i = 0; i < count; i++) {
    if (offset >= end) return null;
    final len = raw[offset];
    if (offset + 1 + len > end) return null;
    segments.add(String.fromCharCodes(raw, offset + 1, offset + 1 + len));
    offset += 1 + len;
  }
  if (offset != end) return null;
  return segments.join(r'\');
}

/// A constant's value read from its flat bytes by the class of the control that draws it:
/// a path, a four-character string, a boolean, or a small non-negative integer, a zero or a
/// double in a plausible range; null when the bytes do not fit the carrier.
Object? decodeBdConstantValue({
  required BdObjectClass carrier,
  required Uint8List? flat,
  required bool scalar,
  bool hasEnumItems = false,
}) {
  if (flat == null) return null;
  final scalarBytes = scalar ? flat.length : null;
  int? scalarValue;
  if (scalar) {
    var magnitude = 0;
    for (final byte in flat) {
      magnitude = (magnitude << 8) | byte;
    }
    scalarValue = magnitude;
  }
  final raw = scalar ? null : flat;
  switch (carrier) {
    case BdObjectClass.path:
      return decodeFlatPathText(raw);
    case BdObjectClass.string:
      if (raw != null && raw.length == 8) {
        final strLen = ByteData.sublistView(raw).getUint32(0);
        if (strLen == 4 && raw.skip(4).every((b) => b >= 0x20 && b < 0x7f)) {
          return String.fromCharCodes(raw, 4);
        }
      }
      return null;
    case BdObjectClass.boolean:
      if (scalarBytes != null && scalarBytes <= 2 && (scalarValue == 0 || scalarValue == 1)) {
        return scalarValue == 1;
      }
      return null;
    case BdObjectClass.enumRing when hasEnumItems:
    case BdObjectClass.typeDefinition when hasEnumItems:
    case BdObjectClass.numeric:
      if (scalarBytes != null && scalarValue != null) {
        if (scalarValue == 0) return scalarValue;
        final leading = (scalarValue >>> (8 * (scalarBytes - 1))) & 0xff;
        if (leading >= 0x80 || scalarValue >= _intCertainCeil) return null;
        return scalarValue;
      }
      if (carrier != BdObjectClass.numeric || raw == null) return null;
      if (_zeroPayloadLengths.contains(raw.length) && raw.every((byte) => byte == 0)) {
        return 0;
      }
      if (raw.length == 8) {
        final f64Reading = ByteData.sublistView(raw).getFloat64(0);
        if (!f64Reading.isFinite) return null;
        if (f64Reading == 0 || (f64Reading.abs() >= _dblWindowFloor && f64Reading.abs() <= _dblWindowCeil)) {
          return f64Reading;
        }
      }
      return null;
    default:
      return null;
  }
}

int? _flatNumericSize(ViDataType kind) => switch (kind) {
  ViDataType.i8 || ViDataType.u8 || ViDataType.enumU8 => 1,
  ViDataType.i16 || ViDataType.u16 || ViDataType.enumU16 => 2,
  ViDataType.i32 || ViDataType.u32 || ViDataType.enumU32 || ViDataType.sgl => 4,
  ViDataType.i64 || ViDataType.u64 || ViDataType.dbl => 8,
  _ => null,
};

num _flatNumericAt(Uint8List flat, int offset, ViDataType kind, int size) {
  if (kind == ViDataType.sgl) return ByteData.sublistView(flat).getFloat32(offset);
  if (kind == ViDataType.dbl) return ByteData.sublistView(flat).getFloat64(offset);
  var value = 0;
  for (var i = 0; i < size; i++) {
    value = (value << 8) | flat[offset + i];
  }
  final signed = kind == ViDataType.i8 || kind == ViDataType.i16 || kind == ViDataType.i32 || kind == ViDataType.i64;
  return signed ? value.toSigned(8 * size) : value;
}

// TODO: payloads stored wider than their numeric type, and arrays of elements other than numbers
// and strings, are not decoded.
void _typedConstDecode(BdConstant constant, ViResolvedType resolved) {
  final flat = constant.raw;
  final type = resolved.type;
  if (flat == null) return;
  final scalarSize = _flatNumericSize(type.kind);
  if (scalarSize != null) {
    if (flat.isEmpty || flat.length > scalarSize) return;
    if (flat.length < scalarSize && (type.kind == ViDataType.sgl || type.kind == ViDataType.dbl)) {
      return;
    }
    final size = flat.length;
    final kind = size < scalarSize ? ViDataType.u64 : type.kind;
    final value = _flatNumericAt(flat, 0, kind, size);
    if (value is double && !value.isFinite) return;
    constant.numeric = value;
    return;
  }
  if (type.kind == ViDataType.string) {
    if (constant.scalar || flat.length < 4) return;
    final declared = ByteData.sublistView(flat).getUint32(0);
    if (4 + declared == flat.length) {
      constant.text = String.fromCharCodes(flat, 4);
    } else if (declared == 0 && flat.length == 5 && flat[4] == 0) {
      constant.text = '';
    }
    return;
  }
  if (type is! ViArrayType) return;
  final element = resolved.elementType;
  final dimCount = type.dimCount;
  if (element == null || dimCount < 1 || dimCount > 8) return;
  final elementSize = _flatNumericSize(element.kind);
  if ((elementSize == null && element.kind != ViDataType.string) || flat.length < 4 * dimCount) return;
  final view = ByteData.sublistView(flat);
  final dims = [for (var d = 0; d < dimCount; d++) view.getUint32(4 * d)];
  var count = 1;
  for (final dim in dims) {
    count *= dim;
  }
  final emptyPadded = count == 0 && flat.length == 4 * dimCount + 1 && flat.last == 0;
  if (elementSize == null) {
    final texts = <String>[];
    var at = 4 * dimCount;
    for (var i = 0; i < count; i++) {
      if (at + 4 > flat.length) return;
      final length = view.getUint32(at);
      if (at + 4 + length > flat.length) return;
      texts.add(String.fromCharCodes(flat, at + 4, at + 4 + length));
      at += 4 + length;
    }
    if (at != flat.length && !emptyPadded) return;
    constant.arrayDims = dims;
    constant.textArray = texts;
    return;
  }
  final expected = 4 * dimCount + count * elementSize;
  if (flat.length != expected && !emptyPadded) return;
  constant.arrayDims = dims;
  constant.array = [
    for (var i = 0; i < count; i++) _flatNumericAt(flat, 4 * dimCount + i * elementSize, element.kind, elementSize),
  ];
}

/// Fills every constant's [BdConstant] fields: through its resolved type first, then through
/// [decodeBdConstantValue] for the fields still unset.
void decodeBdConstValues(BdDiagram diagram) {
  bool subtreeHasItems(BdObject o, [int depth = 0]) {
    if (o case HeapItems(:final items) when items.isNotEmpty) return true;
    if (depth >= 16) return false;
    for (final kid in diagram.childrenOf(o)) {
      if (subtreeHasItems(kid, depth + 1)) return true;
    }
    return false;
  }

  for (final constant in diagram.constants) {
    if (constant.raw == null) continue;
    if (constant.resolvedType case final resolved?) _typedConstDecode(constant, resolved);
    final kids = diagram.childrenOf(constant);
    if (kids.isEmpty) continue;
    final carrier = kids.first.objectClass;
    final wantsItems = carrier == BdObjectClass.enumRing || carrier == BdObjectClass.typeDefinition;
    final value = decodeBdConstantValue(
      carrier: carrier,
      flat: constant.raw,
      scalar: constant.scalar,
      hasEnumItems: wantsItems && subtreeHasItems(constant),
    );
    if (value is bool) constant.boolValue ??= value;
    if (value is num) constant.numeric ??= value;
    if (value is String) constant.text ??= value;
  }
}
