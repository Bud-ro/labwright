/// The record walk both heaps share: [walkHeap] replays a heap body, gathers each object's
/// records on a [HeapScratch] while the object is open, and hands the scratch to the heap's
/// [HeapWalkListener.finalize] when the object closes, which builds the object in the shape its
/// class and records call for. The passes after the walk ([rebaseLabelBounds],
/// [bubbleItemsToControls], [bubbleHelpText], [reanchorScrolledControls]) read the finished
/// [HeapObjectTree].
///
/// Which records feed which shared scratch fields:
///
/// ```text
/// record                                   field
/// object header                            oid, kind, offset, parentOid
/// C4 bounds (0x2d)                         bounds; absBounds accumulates the ancestors' origins
/// C4 size (0x1f)                           termCount, one per record
/// C4 caption (0x22), attribute shortText   caption
/// C4 formatString (0x74)                   typeKind (format conversion character)
/// C4 stringTable (0x2e)                    items
/// C4 description (0x19)                    helpText
/// reference records                        childRefs, dcoRefs
/// attributes                               typeDescIdx, objFlags, displayFormat, bgRgb, fgRgb,
///                                          contentRgb, labelModeWord
/// font run groups                          fontRuns
/// array index group                        arrayIndex
/// ```
library;

import 'dart:math';
import 'dart:typed_data';

import 'heap.dart';
import 'heap_object.dart';

/// The records of one object gathered while the walk is inside it; a heap's listener extends
/// it with the fields its own records and attributes fill. One scratch serves many objects in
/// turn, so [reset] clears every field.
abstract class HeapScratch {
  int oid = 0;
  int kind = 0;
  int offset = 0;
  int end = 0;
  int index = 0;
  int? parentOid;

  /// The enclosing object's class code, null for a root.
  int? parentKind;

  /// The heap-absolute origin the object's children are placed against: the enclosing origin
  /// until the object's bounds record arrives, its own top-left after.
  int originTop = 0;
  int originLeft = 0;

  HeapRect? bounds;
  int boundsOffset = 0;
  HeapRect? absBounds;
  HeapCaption? caption;
  List<int>? childRefs;
  List<int>? dcoRefs;
  int termCount = 0;
  List<String> items = const [];
  String? helpText;
  List<HeapFontRun> fontRuns = const [];
  int typeKindEvidence = 0;
  int? typeDescIdx;
  int? objFlags;
  int? bgRgb;
  int? fgRgb;
  int? contentRgb;
  String? displayFormat;
  int? labelModeWord;
  int? arrayIndex;

  ViTypeKind get typeKind => inferTypeKind(typeKindEvidence);

  /// The `childRef` targets, empty for none.
  List<int> get refs => childRefs ?? const [];

  void reset() {
    oid = kind = offset = end = index = 0;
    parentOid = null;
    parentKind = null;
    originTop = originLeft = 0;
    bounds = null;
    boundsOffset = 0;
    absBounds = null;
    caption = null;
    childRefs = null;
    dcoRefs = null;
    termCount = 0;
    items = const [];
    helpText = null;
    fontRuns = const [];
    typeKindEvidence = 0;
    typeDescIdx = null;
    objFlags = null;
    bgRgb = fgRgb = contentRgb = null;
    displayFormat = null;
    labelModeWord = null;
    arrayIndex = null;
  }
}

/// A group of records the walk routes to one owner object until the group closes: font runs,
/// an array's index group, a case structure's selector lists.
abstract class HeapGroupCapture {
  HeapGroupCapture(this.owner);

  final HeapScratch owner;

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
class FontRunCapture extends HeapGroupCapture {
  FontRunCapture(super.owner);

  final List<HeapFontRun> _runs = [];
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
    if (depth == 0 && _runs.isNotEmpty && owner.fontRuns.isEmpty) owner.fontRuns = _runs;
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
class ArrayIndexCapture extends HeapGroupCapture {
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

/// What one heap adds to the shared walk: its scratch, the groups it captures, the records and
/// attributes it reads beyond the shared ones, and the object each finished scratch becomes.
abstract class HeapWalkListener<T extends HeapObject, S extends HeapScratch> {
  S createScratch();

  /// A capture for the group [tag] that opened under [owner], or null to let the records
  /// through; one capture of a kind is open at a time.
  HeapGroupCapture? captureGroup(S owner, int tag) => null;

  /// The attributes the heap reads beyond the shared ones; the walk decodes no other.
  Set<HeapAttribute> get attributes;

  /// A C4 record the shared walk does not read, with its payload at [start]..[end].
  void onRecord(S cur, int opcode, Uint8List body, int start, int end) {}

  /// An attribute the shared walk does not read; [attr] is reused across records.
  void onAttribute(S cur, HeapAttrReading attr) {}

  /// The object for a scratch whose records are complete; [children] are its finished children
  /// in heap order.
  T finalize(S scratch, List<T> children);
}

/// One attribute record as the walk read it: a scalar word taken straight from the bytes, or
/// the decoded record for every other width.
class HeapAttrReading {
  HeapAttribute attribute = HeapAttribute.unknown;
  int _scalar = 0;
  int _scalarBytes = 0;
  HeapAttr? _decoded;

  void _readScalar(HeapAttribute attribute, int value, int bytes) {
    this.attribute = attribute;
    _scalar = value;
    _scalarBytes = bytes;
    _decoded = null;
  }

  void _readDecoded(HeapAttr attr) {
    attribute = attr.attribute;
    _decoded = attr;
  }

  int? get asInt => _decoded == null ? _scalar : _decoded!.asInt;

  double? get asDouble => _decoded?.asDouble;

  String? get asString => _decoded?.asString;

  String? get asciiText => _decoded?.asciiText;

  HeapRect? get asRect => _decoded?.asRect;

  /// The bytes of a scalar payload; null for a container or point.
  int? get scalarBytes => _decoded == null ? _scalarBytes : heapAttrScalarBytes(_decoded!.width);

  /// The payload as flat bytes: a container's raw bytes, or a scalar's big-endian bytes.
  Uint8List? get flatBytes => _decoded == null ? _bigEndian(_scalar, _scalarBytes) : heapAttrFlatBytes(_decoded!);

  /// A colour payload as `0xRRGGBB`; null for the transparent encodings.
  int? get rgb => _decoded == null ? _scalarColorRgb(_scalar) : _attrColorRgb(_decoded!);
}

Uint8List _bigEndian(int value, int bytes) {
  final out = Uint8List(bytes);
  for (var b = 0; b < bytes; b++) {
    out[b] = (value >> (8 * (bytes - 1 - b))) & 0xff;
  }
  return out;
}

const Set<HeapAttribute> _sharedAttributes = {
  HeapAttribute.backgroundColor,
  HeapAttribute.contentColor,
  HeapAttribute.cosmColorB,
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
  return scalarBytes == null || scalarBytes == 0 || value == null ? null : _bigEndian(value, scalarBytes);
}

int? _scalarColorRgb(int value) {
  final rgb = value & 0xffffff;
  return value == 0x1 || (rgb == 0 && value >>> 24 == 0x01) ? null : rgb;
}

int? _attrColorRgb(HeapAttr attr) =>
    attr.kind == HeapAttrKind.color && attr.value is int ? _scalarColorRgb(attr.value as int) : null;

/// Replays a heap body (the section payload including its length word) into the objects
/// [listener] builds, in header order.
List<T> walkHeap<T extends HeapObject, S extends HeapScratch>(Uint8List body, HeapWalkListener<T, S> listener) {
  final length = body.length;
  final objects = <T?>[];
  final view = ByteData.sublistView(body);
  final attributeRaws = _attributeTable(listener.attributes);
  final reading = HeapAttrReading();
  final pool = <S>[];
  final captures = <HeapGroupCapture>[];

  final scopes = <S?>[];
  final childrenOfScope = <List<T>?>[];
  final rootChildren = <T>[];

  S? cur;
  var curChildren = rootChildren;

  void refreshCurrent() {
    cur = null;
    curChildren = rootChildren;
    for (var i = scopes.length - 1; i >= 0; i--) {
      if (scopes[i] case final scratch?) {
        cur = scratch;
        curChildren = childrenOfScope[i]!;
        break;
      }
    }
  }

  void closeObject(S scratch, List<T> children, int end) {
    scratch.end = end;
    final object = listener.finalize(scratch, children);
    object.index = scratch.index;
    objects[scratch.index] = object;
    scratch.reset();
    pool.add(scratch);
    refreshCurrent();
    curChildren.add(object);
  }

  var next = 4;
  while (next < length) {
    final offset = next;
    final step = recordSkip(body, offset);
    if (step == null || offset + step > length) break;
    next = offset + step;
    final lead = body[offset];
    final headerLength = isHeapObjectHeaderLead(lead) ? heapObjectHeaderLength(body, offset) : 0;
    if (headerLength != 0) {
      final scratch = pool.isEmpty ? listener.createScratch() : pool.removeLast();
      scratch.oid = heapObjectHeaderOid(body, offset, headerLength);
      scratch.kind = heapObjectHeaderKind(body, offset);
      scratch.offset = offset;
      scratch.index = objects.length;
      scratch.parentOid = cur?.oid;
      scratch.parentKind = cur?.kind;
      scratch.originTop = cur?.originTop ?? 0;
      scratch.originLeft = cur?.originLeft ?? 0;
      objects.add(null);
      final children = <T>[];
      scopes.add(scratch);
      childrenOfScope.add(children);
      cur = scratch;
      curChildren = children;
      continue;
    }
    if (isHeapGroupOpenLead(lead) && offset + 4 <= length && isHeapTypeTag(body[offset + 3])) {
      final groupTag = body[offset + 1];
      scopes.add(null);
      childrenOfScope.add(null);
      for (final capture in captures) {
        capture.depth++;
        capture.openGroup(groupTag);
      }
      final owner = cur;
      if (owner == null) continue;
      final capture = groupTag == HeapGroupTag.fontRunList.tag
          ? FontRunCapture(owner)
          : listener.captureGroup(owner, groupTag);
      if (capture != null && !captures.any((open) => open.runtimeType == capture.runtimeType)) captures.add(capture);
      continue;
    }
    if (isHeapGroupCloseLead(lead)) {
      if (scopes.isEmpty) continue;
      final closed = scopes.removeLast();
      final children = childrenOfScope.removeLast();
      if (closed != null) {
        closeObject(closed, children!, next);
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
    final scratch = cur;
    if (scratch == null) continue;
    var consumed = false;
    for (final capture in captures) {
      if (identical(scratch, capture.owner) && capture.record(body, view, offset, lead, step)) {
        consumed = true;
        break;
      }
    }
    if (consumed) continue;
    if (lead == kHeapRecordPrefix) {
      final opcode = body[offset + 1];
      final start = offset + (body[offset + 2] == 0xff ? 5 : 3);
      final end = offset + step;
      scratch.typeKindEvidence |= ViTypeKindEvidence.ofOpcode(opcode);
      switch (opcode) {
        case 0x2d:
          if (scratch.bounds == null && end - start == 8) {
            final bounds = HeapRect(
              top: view.getInt16(start),
              left: view.getInt16(start + 2),
              bottom: view.getInt16(start + 4),
              right: view.getInt16(start + 6),
            );
            scratch.bounds = bounds;
            scratch.boundsOffset = start;
            final top = scratch.originTop + bounds.top;
            final left = scratch.originLeft + bounds.left;
            scratch.originTop = top;
            scratch.originLeft = left;
            scratch.absBounds = bounds.shift(top - bounds.top, left - bounds.left);
          }
        case 0x22:
          if (scratch.caption == null) {
            final text = heapRecordText(Uint8List.sublistView(body, start, end));
            if (text != null) scratch.caption = HeapCaption(text, recordOffset: offset, recordLength: step);
          }
        case 0x1f:
          scratch.termCount++;
        case 0x74:
          if (scratch.typeKindEvidence & ViTypeKindEvidence.numeric.bit == 0) {
            scratch.typeKindEvidence |= ViTypeKindEvidence.ofFormat(Uint8List.sublistView(body, start, end));
          }
        case 0x2e:
          if (scratch.items.isEmpty) scratch.items = _parseEnumItems(Uint8List.sublistView(body, start, end));
        case 0x19:
          scratch.helpText ??= heapDescriptionText(Uint8List.sublistView(body, start, end));
        default:
          listener.onRecord(scratch, opcode, body, start, end);
      }
    } else if (lead == 0x14) {
      if (offset + 6 <= length && body[offset + 2] == 0x01 && body[offset + 3] == 0xfd) {
        final wide = (body[offset + 4] & 0x80) != 0;
        if (!wide || offset + 10 <= length) {
          final target = wide ? view.getUint32(offset + 6) : view.getUint16(offset + 4);
          switch (HeapRefKind.fromRaw(heapRawId(lead, body[offset + 1]))) {
            case HeapRefKind.childRef:
              (scratch.childRefs ??= <int>[]).add(target);
            case HeapRefKind.dcoRef:
              (scratch.dcoRefs ??= <int>[]).add(target);
            default:
              break;
          }
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
        reading._readScalar(attribute, switch (hi) {
          2 => body[offset + 2],
          4 => view.getUint16(offset + 2),
          6 => (view.getUint16(offset + 2) << 8) | body[offset + 4],
          _ => view.getUint32(offset + 2),
        }, scalarBytes);
      } else {
        final attr = decodeHeapAttrIn(view, body, offset);
        if (attr == null) continue;
        reading._readDecoded(attr);
      }
      switch (attribute) {
        case HeapAttribute.typeDescIndex:
          scratch.typeDescIdx ??= reading.asInt;
        case HeapAttribute.objFlags:
          scratch.objFlags ??= reading.asInt;
        case HeapAttribute.backgroundColor:
          scratch.bgRgb ??= reading.rgb;
        case HeapAttribute.fgColor:
          scratch.fgRgb ??= reading.rgb;
        case HeapAttribute.contentColor:
          scratch.contentRgb ??= reading.rgb;
        case HeapAttribute.cosmColorB:
          scratch.labelModeWord ??= reading.asInt;
        case HeapAttribute.shortText:
          final text = reading.asciiText;
          if (text != null && text.length == reading.scalarBytes) scratch.caption ??= HeapCaption(text);
        case HeapAttribute.formatStyle:
          final bytes = reading.flatBytes;
          if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every((b) => b >= 0x20 && b < 0x7f)) {
            scratch.displayFormat ??= String.fromCharCodes(bytes);
          }
        default:
          listener.onAttribute(scratch, reading);
      }
    }
  }

  while (scopes.isNotEmpty) {
    final closed = scopes.removeLast();
    final children = childrenOfScope.removeLast();
    if (closed != null) closeObject(closed, children!, length);
  }
  return objects.cast<T>();
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
    if (object is! HeapTextLabel) continue;
    if (tree.parentOf(object) case HeapPlaced(absBounds: final ownerAbs)) {
      object.absBounds = object.bounds.shift(ownerAbs.top, ownerAbs.left);
    }
  }
}

/// Copies enum and ring items up to the nearest control body, at most twelve levels up.
void bubbleItemsToControls<T extends HeapObject>(HeapObjectTree<T> tree) {
  for (final object in tree.objects) {
    if (object is! HeapItems || object.items.isEmpty) continue;
    var depth = 0;
    for (var po = tree.parentOf(object); po != null && depth < 12; po = tree.parentOf(po), depth++) {
      if (po is HeapControlBody && po.isValueControl) {
        if (po.items.isEmpty) po.items = object.items;
        break;
      }
    }
  }
}

/// Copies an unplaced object's help text up to its nearest placed ancestor.
void bubbleHelpText<T extends HeapObject>(HeapObjectTree<T> tree) {
  for (final object in tree.objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object is HeapPlaced) continue;
    for (var po = tree.parentOf(object); po != null; po = tree.parentOf(po)) {
      if (po is HeapPlaced) {
        po.helpText ??= helpText;
        break;
      }
    }
  }
}

/// Shifts the absolute bounds of [root] and every placed object inside it by ([dLeft], [dTop]).
void shiftSubtree<T extends HeapObject>(HeapObjectTree<T> tree, T root, {required int dTop, required int dLeft}) {
  if (dTop == 0 && dLeft == 0) return;
  final work = <T>[root];
  while (work.isNotEmpty) {
    final object = work.removeLast();
    if (object is HeapPlaced) object.absBounds = object.absBounds.shift(dTop, dLeft);
    work.addAll(tree.childrenOf(object));
  }
}

/// Moves the control bodies under a scrolled pane so the group's top-left sits at the pane's
/// origin.
void reanchorScrolledControls<T extends HeapObject>(HeapObjectTree<T> tree) {
  T? paneOf(T object) {
    for (var po = tree.parentOf(object); po != null; po = tree.parentOf(po)) {
      if (po is HeapPane) return po;
      if (po is HeapControlBody && po.isValueControl || po is HeapPlaced) return null;
    }
    return null;
  }

  final groups = <T, List<HeapControlBody>>{};
  for (final object in tree.objects) {
    if (object is! HeapControlBody || !object.isValueControl) continue;
    final pane = paneOf(object);
    if (pane != null) (groups[pane] ??= []).add(object);
  }

  for (final MapEntry(key: pane, value: controls) in groups.entries) {
    final paneAbs = (pane as HeapPlaced).absBounds;
    final minTop = controls.map((c) => c.bounds.top).reduce(min);
    final minLeft = controls.map((c) => c.bounds.left).reduce(min);
    for (final control in controls) {
      final newTop = paneAbs.top + (control.bounds.top - minTop);
      final newLeft = paneAbs.left + (control.bounds.left - minLeft);
      shiftSubtree(tree, control as T, dTop: newTop - control.absBounds.top, dLeft: newLeft - control.absBounds.left);
    }
  }
}
