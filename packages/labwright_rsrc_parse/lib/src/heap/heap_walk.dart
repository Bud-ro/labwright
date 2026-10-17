/// The record walk both heaps share: [walkHeap] replays a heap body and turns every object
/// header into a [HeapObject] through a [HeapWalkListener], fills the fields every heap
/// carries, and hands the records it does not read to the listener. The passes after the walk
/// ([rebaseLabelBounds], [bubbleItemsToControls], [bubbleHelpText],
/// [reanchorScrolledControls]) read the finished [HeapObjectTree].
///
/// Which records feed which shared fields:
///
/// ```text
/// record                                   field
/// object header                            oid, kind, offset, parentOid
/// C4 bounds (0x2d)                         bounds; absBounds accumulates the ancestors' origins
/// C4 size (0x1f)                           termCount, one per record
/// C4 caption (0x22), attribute shortText   label
/// C4 formatString (0x74)                   typeKind (format conversion character)
/// C4 stringTable (0x2e)                    items
/// C4 description (0x19)                    helpText
/// reference records                        refs (childRef targets), refsOf (every kind)
/// attributes                               typeDescIdx, objFlags, displayFormat, bgRgb, fgRgb,
///                                          contentRgb
/// font run groups                          textStyleRuns
/// ```
library;

import 'dart:math';
import 'dart:typed_data';

import 'heap.dart';
import 'heap_object.dart';

/// A group of records the walk routes to one owner object until the group closes: font runs,
/// an array's index group, a case structure's selector lists.
abstract class HeapGroupCapture<T extends HeapObject> {
  HeapGroupCapture(this.owner);

  final T owner;

  /// How many groups are open inside the capture, the capture's own group included.
  int depth = 1;

  /// A group with [tag] opened inside the capture, now at [depth].
  void openGroup(int tag) {}

  /// A group closed inside the capture; [depth] is already decremented and zero when the
  /// capture's own group closed.
  void closeGroup() {}

  /// A record in the owner's scope; true when the capture consumed it.
  bool record(Uint8List body, ByteData view, int offset, int lead, int length) => false;
}

/// The font runs of an object's text.
class FontRunCapture<T extends HeapObject> extends HeapGroupCapture<T> {
  FontRunCapture(super.owner);

  final List<({int start, int fontId})> _runs = [];
  bool _runOpen = false;
  int _start = 0;
  int _fontId = 0;

  @override
  void openGroup(int tag) {
    if (tag == HeapGroupTag.fontRun.tag && depth == 2) {
      _runOpen = true;
      _start = 0;
      _fontId = 0;
    }
  }

  @override
  void closeGroup() {
    if (_runOpen && depth == 1) {
      _runs.add((start: _start, fontId: _fontId));
      _runOpen = false;
    }
    if (depth == 0 && _runs.isNotEmpty && owner.textStyleRuns.isEmpty) owner.textStyleRuns = _runs;
  }

  @override
  bool record(Uint8List body, ByteData view, int offset, int lead, int length) {
    if (!_runOpen) return false;
    final attr = decodeHeapAttrIn(view, body, offset);
    final value = attr?.asInt;
    if (attr == null || value == null) return false;
    if (attr.rawTag == FontRunAttr.start.raw) {
      _start = value;
      return true;
    }
    if (attr.rawTag == FontRunAttr.fontId.raw) {
      _fontId = value;
      return true;
    }
    return false;
  }
}

/// The displayed element index of an array container.
class ArrayIndexCapture<T extends HeapObject> extends HeapGroupCapture<T> {
  ArrayIndexCapture(super.owner);

  @override
  bool record(Uint8List body, ByteData view, int offset, int lead, int length) {
    final attr = decodeHeapAttrIn(view, body, offset);
    final value = attr?.asInt;
    if (value == null || attr == null || attr.rawTag != HeapAttribute.arrayElemValue.raw) return false;
    owner.arrayIndex = value;
    return true;
  }
}

/// What one heap adds to the shared walk: its object type, the groups it captures and the
/// records and attributes it reads beyond the shared ones.
abstract class HeapWalkListener<T extends HeapObject> {
  T createObject({required int oid, required int kind, required int offset});

  /// A capture for the group [tag] that opened under [owner], or null to let the records
  /// through.
  HeapGroupCapture<T>? captureGroup(T owner, int tag) => null;

  /// The attributes the heap reads beyond the shared ones; the walk decodes no other.
  Set<HeapAttribute> get attributes;

  /// A C4 record the shared walk does not read, with its payload at [start]..[end].
  void onRecord(T cur, int opcode, Uint8List body, int start, int end) {}

  /// A scalar attribute read on the fast path: [value] is its [scalarBytes]-wide payload.
  void onScalarAttribute(T cur, HeapAttribute attribute, int value, int scalarBytes) {}

  /// A decoded attribute the fast path did not take.
  void onAttribute(T cur, HeapAttr attr) {}
}

const Set<HeapAttribute> _sharedAttributes = {
  HeapAttribute.backgroundColor,
  HeapAttribute.contentColor,
  HeapAttribute.fgColor,
  HeapAttribute.formatStyle,
  HeapAttribute.objFlags,
  HeapAttribute.shortText,
  HeapAttribute.typeDescIndex,
};

List<bool> _attributeTable(Set<HeapAttribute> own) {
  final table = List<bool>.filled(kHeapRawIdCount, false);
  for (final attribute in _sharedAttributes) {
    table[attribute.raw] = true;
  }
  for (final attribute in own) {
    table[attribute.raw] = true;
  }
  return table;
}

/// The bytes a scalar attribute of [width] carries; null for a container or point.
int? heapAttrScalarBytes(HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.flag => 0,
  HeapAttrWidth.u8 => 1,
  HeapAttrWidth.u16 => 2,
  HeapAttrWidth.u24 => 3,
  HeapAttrWidth.rgb => 4,
  _ => null,
};

/// An attribute's payload as flat bytes: a container's raw bytes, or a scalar's big-endian
/// bytes.
Uint8List? heapAttrFlatBytes(HeapAttr record) {
  final raw = record.rawValueBytes;
  if (raw != null) return raw;
  final scalarBytes = heapAttrScalarBytes(record.width);
  final value = record.asInt;
  if (scalarBytes == null || scalarBytes == 0 || value == null) return null;
  final out = Uint8List(scalarBytes);
  for (var i = 0; i < scalarBytes; i++) {
    out[i] = (value >> (8 * (scalarBytes - 1 - i))) & 0xff;
  }
  return out;
}

/// A colour attribute's fast-path word as `0xRRGGBB`; null for the transparent encodings.
int? heapScalarColorRgb(int value) {
  final rgb = value & 0xffffff;
  return value == 0x1 || (rgb == 0 && value >>> 24 == 0x01) ? null : rgb;
}

/// A decoded colour attribute as `0xRRGGBB`; null for the transparent encodings.
int? heapAttrColorRgb(HeapAttr attr) {
  final rawColor = attr.kind == HeapAttrKind.color && attr.value is int ? attr.value as int : null;
  return attr.isTransparent || rawColor == 0x1 ? null : attr.rgb;
}

/// Replays a heap body (the section payload including its length word) into [listener]'s
/// objects, each with its [HeapObject.end] and inferred [HeapObject.typeKind] set.
List<T> walkHeap<T extends HeapObject>(Uint8List body, HeapWalkListener<T> listener) {
  final objects = <T>[];
  final length = body.length;
  final objectCapacity = length ~/ kHeapObjectHeaderMinLength + 1;
  final typeKindEvidence = Int32List(objectCapacity);
  final originTop = Int32List(objectCapacity);
  final originLeft = Int32List(objectCapacity);
  final view = ByteData.sublistView(body);
  final attributeRaws = _attributeTable(listener.attributes);

  final captures = <HeapGroupCapture<T>>[];
  final scopes = <T?>[];
  final groupTags = <int?>[];
  var next = 4;
  while (next < length) {
    final offset = next;
    final step = recordSkip(body, offset);
    if (step == null || offset + step > length) break;
    next = offset + step;
    final recordLength = step;
    final lead = body[offset];
    final cur = scopes.isEmpty ? null : scopes.last;
    final headerLength = isHeapObjectHeaderLead(lead) ? heapObjectHeaderLength(body, offset) : 0;
    if (headerLength != 0) {
      final index = objects.length;
      final object = listener.createObject(
        oid: heapObjectHeaderOid(body, offset, headerLength),
        kind: heapObjectHeaderKind(body, offset),
        offset: offset,
      )..index = index;
      object.parentOid = cur?.oid;
      originTop[index] = cur == null ? 0 : originTop[cur.index];
      originLeft[index] = cur == null ? 0 : originLeft[cur.index];
      objects.add(object);
      scopes.add(object);
      groupTags.add(null);
      continue;
    }
    if (isHeapGroupOpenLead(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      final groupTag = body[offset + 1];
      scopes.add(cur);
      groupTags.add(groupTag);
      var fontRunsOpen = false;
      for (final capture in captures) {
        capture.depth++;
        capture.openGroup(groupTag);
        if (capture is FontRunCapture<T>) fontRunsOpen = true;
      }
      if (cur == null) continue;
      if (groupTag == HeapGroupTag.fontRunList.tag) {
        if (!fontRunsOpen) captures.add(FontRunCapture(cur));
      } else if (listener.captureGroup(cur, groupTag) case final capture?) {
        captures.add(capture);
      }
      continue;
    }
    if (isHeapGroupCloseLead(lead)) {
      if (scopes.isEmpty) continue;
      final closed = scopes.removeLast();
      final groupTag = groupTags.removeLast();
      if (groupTag == null) {
        closed?.end = next;
        continue;
      }
      for (var i = 0; i < captures.length; i++) {
        final capture = captures[i];
        capture.depth--;
        capture.closeGroup();
        if (capture.depth == 0) captures.removeAt(i--);
      }
      continue;
    }
    if (cur == null) continue;
    var consumed = false;
    for (final capture in captures) {
      if (identical(cur, capture.owner) && capture.record(body, view, offset, lead, recordLength)) {
        consumed = true;
        break;
      }
    }
    if (consumed) continue;
    if (lead == kHeapRecordPrefix) {
      final opcode = body[offset + 1];
      final start = offset + (body[offset + 2] == 0xff ? 5 : 3);
      final end = offset + recordLength;
      typeKindEvidence[cur.index] |= ViTypeKindEvidence.ofOpcode(opcode);
      switch (opcode) {
        case 0x2d:
          if (cur.bounds == null && end - start == 8) {
            final bounds = HeapRect(
              top: view.getInt16(start),
              left: view.getInt16(start + 2),
              bottom: view.getInt16(start + 4),
              right: view.getInt16(start + 6),
            );
            cur.bounds = bounds;
            cur.boundsOffset = start;
            final top = originTop[cur.index] + bounds.top;
            final left = originLeft[cur.index] + bounds.left;
            originTop[cur.index] = top;
            originLeft[cur.index] = left;
            cur.absBounds = HeapRect(top: top, left: left, bottom: top + bounds.height, right: left + bounds.width);
          }
        case 0x22:
          if (cur.label == null) {
            cur.label = heapRecordText(Uint8List.sublistView(body, start, end));
            if (cur.label != null) {
              cur.labelOffset = offset;
              cur.labelLength = recordLength;
            }
          }
        case 0x1f:
          cur.termCount++;
        case 0x74:
          if (typeKindEvidence[cur.index] & ViTypeKindEvidence.numeric.bit == 0) {
            typeKindEvidence[cur.index] |= ViTypeKindEvidence.ofFormat(Uint8List.sublistView(body, start, end));
          }
        case 0x2e:
          if (cur.items.isEmpty) cur.items = _parseEnumItems(Uint8List.sublistView(body, start, end));
        case 0x19:
          cur.helpText ??= heapDescriptionText(Uint8List.sublistView(body, start, end));
        default:
          listener.onRecord(cur, opcode, body, start, end);
      }
    } else if (lead == 0x14) {
      if (offset + 6 <= length && body[offset + 2] == 0x01 && body[offset + 3] == 0xfd) {
        final wide = (body[offset + 4] & 0x80) != 0;
        if (!wide || offset + 10 <= length) {
          cur.addRef(
            HeapRefKind.fromRaw(heapRawId(lead, body[offset + 1])),
            wide ? view.getUint32(offset + 6) : view.getUint16(offset + 4),
          );
        }
      }
    } else if (offset + 1 < length && attributeRaws[heapRawId(lead, body[offset + 1])]) {
      final attribute = HeapAttribute.fromRaw(heapRawId(lead, body[offset + 1]));
      final lo = lead & 0xf, hi = lead >> 4;
      final scalarBytes = hi >> 1;
      if ((lo == 4 || lo == 5 || lo == 6) &&
          (hi == 2 || hi == 4 || hi == 6 || hi == 8) &&
          offset + 2 + scalarBytes <= length &&
          attribute != HeapAttribute.shortText &&
          attribute != HeapAttribute.constValue &&
          attribute != HeapAttribute.formatStyle) {
        final value = switch (hi) {
          2 => body[offset + 2],
          4 => view.getUint16(offset + 2),
          6 => (view.getUint16(offset + 2) << 8) | body[offset + 4],
          _ => view.getUint32(offset + 2),
        };
        switch (attribute) {
          case HeapAttribute.typeDescIndex:
            cur.typeDescIdx ??= value;
          case HeapAttribute.objFlags:
            cur.objFlags ??= value;
          case HeapAttribute.backgroundColor:
            cur.bgRgb ??= heapScalarColorRgb(value);
          case HeapAttribute.fgColor:
            cur.fgRgb ??= heapScalarColorRgb(value);
          case HeapAttribute.contentColor:
            cur.contentRgb ??= heapScalarColorRgb(value);
          default:
            listener.onScalarAttribute(cur, attribute, value, scalarBytes);
        }
        continue;
      }
      final attr = decodeHeapAttrIn(view, body, offset);
      if (attr == null) continue;
      switch (attr.attribute) {
        case HeapAttribute.shortText:
          final text = attr.asciiText;
          if (text != null && text.length == heapAttrScalarBytes(attr.width)) cur.label ??= text;
        case HeapAttribute.formatStyle:
          final bytes = heapAttrFlatBytes(attr);
          if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every((b) => b >= 0x20 && b < 0x7f)) {
            cur.displayFormat ??= String.fromCharCodes(bytes);
          }
        case HeapAttribute.typeDescIndex:
          cur.typeDescIdx ??= attr.asInt;
        case HeapAttribute.objFlags:
          cur.objFlags ??= attr.asInt;
        case HeapAttribute.backgroundColor:
          cur.bgRgb ??= heapAttrColorRgb(attr);
        case HeapAttribute.fgColor:
          cur.fgRgb ??= heapAttrColorRgb(attr);
        case HeapAttribute.contentColor:
          cur.contentRgb ??= heapAttrColorRgb(attr);
        default:
          listener.onAttribute(cur, attr);
      }
    }
  }

  for (final object in objects) {
    if (object.end == 0) object.end = length;
    object.typeKind = inferTypeKind(typeKindEvidence[object.index]);
  }
  return objects;
}

List<String> _parseEnumItems(List<int> payload) {
  final out = <String>[];
  var i = 0;
  while (i < payload.length) {
    final len = payload[i++];
    if (len == 0) continue;
    if (i + len > payload.length) return const [];
    final text = String.fromCharCodes(payload.sublist(i, i + len));
    i += len;
    if (!text.codeUnits.every((c) => c >= 0x20 && c < 0x7f)) return const [];
    out.add(text);
  }
  return out;
}

/// Re-bases every label's absolute bounds on its owner's, since a label's bounds record is
/// relative to the owner rather than the enclosing origin.
void rebaseLabelBounds<T extends HeapObject>(HeapObjectTree<T> tree) {
  for (final object in tree.objects) {
    if (!object.isTextLabel) continue;
    final parent = tree.parentOf(object);
    final local = object.bounds;
    final ownerBounds = parent?.bounds;
    final ownerAbs = parent?.absBounds;
    if (local == null || ownerBounds == null || ownerAbs == null) continue;
    object.absBounds = HeapRect(
      top: ownerAbs.top + local.top,
      left: ownerAbs.left + local.left,
      bottom: ownerAbs.top + local.top + local.height,
      right: ownerAbs.left + local.left + local.width,
    );
  }
}

/// Copies enum and ring items up to the nearest ancestor [isControl] accepts.
void bubbleItemsToControls<T extends HeapObject>(HeapObjectTree<T> tree, {required bool Function(T) isControl}) {
  for (final object in tree.objects) {
    if (object.items.isEmpty) continue;
    var parentOid = object.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 12) {
      final po = tree.byId[parentOid];
      if (po == null) break;
      if (isControl(po)) {
        if (po.items.isEmpty) po.items = object.items;
        break;
      }
      parentOid = po.parentOid;
      depth++;
    }
  }
}

/// Copies an unbounded object's help text up to its nearest bounded ancestor.
void bubbleHelpText<T extends HeapObject>(HeapObjectTree<T> tree) {
  for (final object in tree.objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object.absBounds != null) continue;
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null && seen.add(parentOid)) {
      final po = tree.byId[parentOid];
      if (po == null) break;
      if (po.absBounds != null) {
        po.helpText ??= helpText;
        break;
      }
      parentOid = po.parentOid;
    }
  }
}

/// Shifts the absolute bounds of [root] and everything inside it by ([dLeft], [dTop]).
void shiftSubtree<T extends HeapObject>(HeapObjectTree<T> tree, T root, {required int dTop, required int dLeft}) {
  if (dTop == 0 && dLeft == 0) return;
  final seen = <T>{root};
  final expanded = <int>{};
  final work = <T>[root];
  while (work.isNotEmpty) {
    final object = work.removeLast();
    final bounds = object.absBounds;
    if (bounds != null) {
      object.absBounds = HeapRect(
        top: bounds.top + dTop,
        left: bounds.left + dLeft,
        bottom: bounds.bottom + dTop,
        right: bounds.right + dLeft,
      );
    }
    if (!expanded.add(object.oid)) continue;
    for (final child in tree.childrenOf(object)) {
      if (seen.add(child)) work.add(child);
    }
  }
}

/// Moves the controls under a scrolled viewport ([isPane]) so the group's top-left sits at the
/// viewport's origin.
void reanchorScrolledControls<T extends HeapObject>(
  HeapObjectTree<T> tree, {
  required bool Function(T) isPane,
  required bool Function(T) isControl,
}) {
  final objects = tree.objects;
  final byOid = tree.byId;
  int? reanchorViewport(T object) {
    var parentOid = object.parentOid;
    for (var depth = 0; parentOid != null && depth < objects.length; depth++) {
      final po = byOid[parentOid];
      if (po == null) return null;
      if (isPane(po)) return po.oid;
      if (isControl(po) || po.bounds != null) return null;
      parentOid = po.parentOid;
    }
    return null;
  }

  final groups = <int, List<T>>{};
  for (final object in objects) {
    if (!isControl(object) || object.bounds == null || object.absBounds == null) continue;
    final viewport = reanchorViewport(object);
    if (viewport != null) (groups[viewport] ??= <T>[]).add(object);
  }

  for (final MapEntry(key: vOid, value: controls) in groups.entries) {
    final viewport = byOid[vOid];
    if (viewport?.absBounds == null) continue;
    final minTop = controls.map((c) => c.bounds!.top).reduce(min);
    final minLeft = controls.map((c) => c.bounds!.left).reduce(min);
    for (final control in controls) {
      final newTop = viewport!.absBounds!.top + (control.bounds!.top - minTop);
      final newLeft = viewport.absBounds!.left + (control.bounds!.left - minLeft);
      shiftSubtree(
        tree,
        control,
        dTop: newTop - control.absBounds!.top,
        dLeft: newLeft - control.absBounds!.left,
      );
    }
  }
}
