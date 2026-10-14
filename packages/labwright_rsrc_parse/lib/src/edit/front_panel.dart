import 'dart:typed_data';

import '../block_tag.dart';
import '../diagram/objects.dart';
import '../heap/heap.dart';
import '../heap/heap_tree.dart';
import '../model.dart';
import '../section_buffer.dart';
import 'empty_vi.dart';
import 'records.dart';

/// The front panel of a model over the heap's own records: the pane's control list, which
/// [addControl] extends, and [write] to put the heap back into the model.
class FpEditor {
  FpEditor._(this.model, this.section, this.tree, this._frame, this._viewport);

  factory FpEditor.lift(ViModel model) {
    final section = model.section(BlockTag.fphb.tag);
    if (section == null) throw StateError('the model has no front panel heap');
    final tree = parseHeapTree(section.bytes);
    final root = tree.objects.firstWhere((o) => o.kind == HeapObjectClass.diagramRoot.code);
    final frame = root.children.objects.firstWhere((o) => o.kind == HeapObjectClass.diagramFrame.code);
    final viewport = _firstViewport(frame.children);
    if (viewport == null) throw StateError('the panel has no pane');
    return FpEditor._(model, section, tree, frame, viewport);
  }

  /// The first pane viewport below [nodes], depth first: the pane of a split panel that
  /// comes first in its records.
  static HeapObjectNode? _firstViewport(List<HeapNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case HeapObjectNode():
          if (node.kind == HeapObjectClass.contentViewport.code) return node;
          final below = _firstViewport(node.children);
          if (below != null) return below;
        case HeapGroupNode():
          final below = _firstViewport(node.children);
          if (below != null) return below;
        case HeapRecordNode():
          break;
      }
    }
    return null;
  }

  final ViModel model;

  final ViSectionBuffer section;

  final List<HeapNode> tree;

  final HeapObjectNode _frame;

  final HeapObjectNode _viewport;

  bool _touched = false;

  HeapGroupNode get _controls =>
      _viewport.children.whereType<HeapGroupNode>().firstWhere((g) => g.rawId == kPanelControlList);

  HeapGroupNode get _controlRefs =>
      _frame.children.whereType<HeapGroupNode>().firstWhere((g) => g.rawId == kPanelControlRefs);

  /// The controls on the pane, in record order.
  Iterable<HeapObjectNode> get controls => _controls.children.objects;

  /// Whether the panel object [oid] is an indicator; null when the panel has no such object.
  bool? isIndicator(int oid) {
    final node = _find(tree, oid);
    return node == null ? null : (node.children.attr(HeapAttribute.objFlags)?.asInt ?? 0) & 1 != 0;
  }

  static HeapObjectNode? _find(List<HeapNode> nodes, int oid) {
    for (final node in nodes) {
      switch (node) {
        case HeapObjectNode():
          if (node.oid == oid) return node;
          final below = _find(node.children, oid);
          if (below != null) return below;
        case HeapGroupNode():
          final below = _find(node.children, oid);
          if (below != null) return below;
        case HeapRecordNode():
          break;
      }
    }
    return null;
  }

  /// Adds a control or indicator of the type in heap slot [slot] named [name] below the
  /// others, and returns its object id, [oid].
  int addControl(
    int oid, {
    required int controlOid,
    required int labelOid,
    required int slot,
    required int controlSlot,
    required String name,
    required bool indicator,
  }) {
    final row = controls.length;
    final top = kFpFirstControlTop + row * kFpControlPitch;
    final node = object(
      HeapObjectClass.node.code,
      oid,
      children: [
        attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x10200 | (indicator ? 1 : 0)),
        attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, slot),
        object(
          HeapObjectClass.numericControl.code,
          controlOid,
          rawTag: HeapRefKind.ddoRef.raw,
          children: [
            attr(HeapAttribute.objFlags, HeapAttrWidth.rgb, 0x40060002),
            c4Rect(
              HeapOpcode.bounds,
              HeapRect(
                top: top,
                left: kFpControlLeft,
                bottom: top + kFpControlHeight,
                right: kFpControlLeft + kFpControlWidth,
              ),
            ),
            list(kControlParts, [
              object(
                HeapObjectClass.controlLabel.code,
                labelOid,
                children: [
                  attr(HeapAttribute.objFlags, HeapAttrWidth.u24, 0x170146),
                  attr(HeapAttribute.partRole, HeapAttrWidth.u8, 0x10),
                  attr(HeapAttribute.masterPart, HeapAttrWidth.u8, 9),
                  attr(HeapAttribute.howGrow, HeapAttrWidth.u16, 0x1000),
                  c4Rect(HeapOpcode.bounds, HeapRect(top: 0, left: 0, bottom: 17, right: name.length * 7)),
                  worded(kPartOffset, kPartOffsetWord, [attr(HeapAttribute.relativeOffset, HeapAttrWidth.u8, 0xf7)]),
                  attr(HeapAttribute.fgColor, HeapAttrWidth.rgb, kTransparent),
                  attr(HeapAttribute.backgroundColor, HeapAttrWidth.rgb, kTransparent),
                  worded(kPartText, kPartTextWord, [
                    attr(HeapAttribute.cosmFgColor, HeapAttrWidth.u16, 0x600),
                    attr(HeapAttribute.cosmColorB, HeapAttrWidth.u16, 0x4404),
                    caption(name),
                    attr(HeapAttribute.contentColor, HeapAttrWidth.rgb, kTransparent),
                  ]),
                ],
              ),
            ]),
            attr(HeapAttribute.typeDescIndex, HeapAttrWidth.u8, controlSlot),
            attr(HeapAttribute.mouseWheelSupport, HeapAttrWidth.u8, 2),
          ],
        ),
        attr(HeapAttribute.termListLength, HeapAttrWidth.u8, 1),
      ],
    );
    _controls.children.add(node);
    _controls.syncCount();
    _controlRefs.children.add(ref(HeapRefKind.childRef, oid));
    _controlRefs.syncCount();
    _touched = true;
    return oid;
  }

  /// Writes the heap back into the model's section when a control was added, and rebuilds
  /// the model's panel diagrams from it.
  void write() {
    if (!_touched) return;
    section.replace(encodeHeapTree(tree));
    for (final diagram in model.frontPanelDiagrams) {
      if (diagram.sectionIndex == section.index) model.reloadDiagram(diagram);
    }
    _touched = false;
  }

  Uint8List encode() => encodeHeapTree(tree);
}

/// Where new controls go on the pane: a column from [kFpFirstControlTop] down, one
/// [kFpControlPitch] apart, each [kFpControlWidth] by [kFpControlHeight].
const int kFpFirstControlTop = 20;

const int kFpControlLeft = 48;

const int kFpControlPitch = 60;

const int kFpControlWidth = 79;

const int kFpControlHeight = 42;
