part of '../graph.dart';

final Set<int> kViSelectorGroupTags = {
  HeapGroupTag.selectorRangeList.tag,
  HeapGroupTag.selectorRangeListAlt.tag,
  HeapGroupTag.selectorStringPool.tag,
};

const _diagramAttrIds = {
  0x20, 0x21, 0x6c, 0x24, 0x28, 0x6f, 0x19, 0x2b, 0x2a, 0x29, 0x3a, 0xcb, 0xea, 0xe7, 0x4d, 0x9f, 0x22, 0x74, //
  0x54,
};

const int _structureAreaCap = 20000;

const int _ancestorSearchDepth = 12;

int _signedAtWidth(int value, HeapAttrWidth width) {
  final bytes = width.scalarBytes;
  return bytes == null || bytes == 0 ? value : value.toSigned(8 * bytes);
}

Uint8List? _attrFlatBytes(HeapAttr record) {
  final raw = record.rawValueBytes;
  if (raw != null) return raw;
  final scalarBytes = record.width.scalarBytes;
  final value = record.asInt;
  if (scalarBytes == null || scalarBytes == 0 || value == null) return null;
  return _bigEndianBytes(value, scalarBytes);
}

Uint8List _bigEndianBytes(int value, int count) {
  final out = Uint8List(count);
  for (var index = 0; index < count; index++) {
    out[index] = (value >> (8 * (count - 1 - index))) & 0xff;
  }
  return out;
}

String? _selectorPoolString(Uint8List body, int offset, int lead, int span) {
  if (lead == kHeapRecordPrefix) {
    if (offset + 3 > body.length) return null;
    final count = body[offset + 2];
    if (3 + count > span || offset + 3 + count > body.length) return null;
    return String.fromCharCodes(body.sublist(offset + 3, offset + 3 + count));
  }
  final attr = decodeHeapAttr(body, offset);
  final value = attr?.asInt;
  if (value == null) return null;
  final chars = _bigEndianBytes(value, attr!.width.scalarBytes ?? 0);
  return String.fromCharCodes(chars.skipWhile((char) => char == 0));
}

class _SelectorCollector {
  _SelectorCollector(this.owner, {required this.isPool});

  final ViHeapObject owner;

  final bool isPool;

  int depth = 1;

  final ranges = <ViSelectorRange>[];

  final strings = <String>[];

  bool entryOpen = false;

  int low = 0, high = 0, lowBound = 0, highBound = 0, frame = 0;

  void groupOpened(int groupTag) {
    depth++;
    if (groupTag == HeapGroupTag.selectorRange.tag && depth == 2 && !isPool) {
      entryOpen = true;
      low = high = lowBound = highBound = frame = 0;
    }
  }

  bool groupClosed() {
    if (entryOpen && depth == 2) {
      ranges.add(
        ViSelectorRange(
          low: low,
          high: high,
          lowBound: ViSelectorBound.ofCode(lowBound),
          highBound: ViSelectorBound.ofCode(highBound),
          frame: frame,
        ),
      );
      entryOpen = false;
    }
    if (--depth != 0) return false;
    if (isPool) {
      if (owner.selectorStrings.isEmpty) owner.selectorStrings = strings;
    } else if (owner.selectorRanges.isEmpty) {
      owner.selectorRanges = ranges;
    }
    return true;
  }

  bool record(Uint8List body, int offset, int lead, int span) {
    if (isPool) {
      final value = _selectorPoolString(body, offset, lead, span);
      if (value == null) return false;
      strings.add(value);
      return true;
    }
    if (!entryOpen) return false;
    final attr = decodeHeapAttr(body, offset);
    final value = attr?.asInt;
    if (value == null) return false;
    final tag = attr!.rawTag;
    if (tag == SelectorRangeAttr.low.raw) {
      low = _signedAtWidth(value, attr.width);
    } else if (tag == SelectorRangeAttr.high.raw) {
      high = _signedAtWidth(value, attr.width);
    } else if (tag == SelectorRangeAttr.lowBound.raw) {
      lowBound = value;
    } else if (tag == SelectorRangeAttr.highBound.raw) {
      highBound = value;
    } else if (tag == SelectorRangeAttr.frame.raw) {
      frame = value;
    } else {
      return false;
    }
    return true;
  }
}

class _ArrayIndexCollector {
  _ArrayIndexCollector(this.owner);

  final ViHeapObject owner;

  int depth = 1;

  bool record(Uint8List body, int offset) {
    final attr = decodeHeapAttr(body, offset);
    final value = attr?.asInt;
    if (value == null || attr!.rawTag != HeapAttribute.arrayElemValue.raw) return false;
    owner.arrayIndex = value;
    return true;
  }
}

class _FontRunCollector {
  _FontRunCollector(this.owner);

  final ViHeapObject owner;

  int depth = 1;

  final runs = <({int start, int fontId})>[];

  bool runOpen = false;

  int start = 0, fontId = 0;

  void groupOpened(int groupTag) {
    depth++;
    if (groupTag == HeapGroupTag.fontRun.tag && depth == 2) {
      runOpen = true;
      start = 0;
      fontId = 0;
    }
  }

  bool groupClosed() {
    depth--;
    if (runOpen && depth == 1) {
      runs.add((start: start, fontId: fontId));
      runOpen = false;
    }
    if (depth != 0) return false;
    if (runs.isNotEmpty && owner.textStyleRuns.isEmpty) owner.textStyleRuns = runs;
    return true;
  }

  bool record(Uint8List body, int offset) {
    if (!runOpen) return false;
    final attr = decodeHeapAttr(body, offset);
    final value = attr?.asInt;
    if (value == null) return false;
    if (attr!.rawTag == FontRunAttr.start.raw) {
      start = value;
    } else if (attr.rawTag == FontRunAttr.fontId.raw) {
      fontId = value;
    } else {
      return false;
    }
    return true;
  }
}

class _DiagramBuild {
  _DiagramBuild(this.body, this.sectionTag);

  final Uint8List body;

  final String sectionTag;

  final objects = <ViHeapObject>[];

  final c4ops = <ViHeapObject, Set<int>>{};

  final formatPayloads = <ViHeapObject, List<int>>{};

  final absTop = <ViHeapObject, int>{};

  final absLeft = <ViHeapObject, int>{};

  final liveParent = <ViHeapObject, ViHeapObject?>{};

  _SelectorCollector? selector;

  _ArrayIndexCollector? arrayIndex;

  _FontRunCollector? fontRuns;

  void groupOpened(int groupTag, ViHeapObject? object) {
    if (selector != null) {
      selector!.groupOpened(groupTag);
    } else if (object != null &&
        object.objectClass == HeapObjectClass.bdStructureFrame &&
        kViSelectorGroupTags.contains(groupTag)) {
      selector = _SelectorCollector(object, isPool: groupTag == HeapGroupTag.selectorStringPool.tag);
    }
    if (arrayIndex != null) {
      arrayIndex!.depth++;
    } else if (groupTag == HeapGroupTag.arrayIndex.tag &&
        object != null &&
        object.objectClass == HeapObjectClass.caseOrSequence) {
      arrayIndex = _ArrayIndexCollector(object);
    }
    if (fontRuns != null) {
      fontRuns!.groupOpened(groupTag);
    } else if (groupTag == HeapGroupTag.fontRunList.tag && object != null) {
      fontRuns = _FontRunCollector(object);
    }
  }

  void groupClosed() {
    if (selector != null && selector!.groupClosed()) selector = null;
    if (arrayIndex != null && --arrayIndex!.depth == 0) arrayIndex = null;
    if (fontRuns != null && fontRuns!.groupClosed()) fontRuns = null;
  }

  ViHeapObject objectOpened(HeapSpan span, int kind, int oid, ViHeapObject? parent) {
    final object = ViHeapObject(oid: oid, kind: kind, offset: span.offset);
    object.parentOid = parent?.oid;
    liveParent[object] = parent;
    absTop[object] = absTop[parent] ?? 0;
    absLeft[object] = absLeft[parent] ?? 0;
    objects.add(object);
    c4ops[object] = <int>{};
    return object;
  }

  void record(HeapSpan span, ViHeapObject? object) {
    if (object == null) return;
    final offset = span.offset;
    final lead = span.lead;
    if (selector != null && identical(object, selector!.owner) && selector!.record(body, offset, lead, span.length)) {
      return;
    }
    if (arrayIndex != null && identical(object, arrayIndex!.owner) && arrayIndex!.record(body, offset)) return;
    if (fontRuns != null && identical(object, fontRuns!.owner) && fontRuns!.record(body, offset)) return;
    if (lead == kHeapRecordPrefix) {
      final frame = c4FrameAt(body, offset, sectionTag);
      if (frame != null) applyFrameRecord(object, frame);
    } else if (lead == 0x14) {
      final ref = decodeHeapRef(body, offset);
      if (ref == null) return;
      (object.typedRefs[ref.kind] ??= <int>[]).add(ref.targetOid);
      if (ref.kind == HeapRefKind.childRef) object.refs.add(ref.targetOid);
    } else if (offset + 1 < body.length && _diagramAttrIds.contains(body[offset + 1])) {
      final attr = decodeHeapAttr(body, offset);
      if (attr != null) applyAttribute(object, attr);
    }
  }

  void applyFrameRecord(ViHeapObject object, HeapRecord frame) {
    c4ops[object]!.add(frame.opcode);
    switch (frame.kind) {
      case HeapOpcode.bounds:
        final bounds = frame.bounds;
        if (object.bounds == null && bounds != null) {
          object.bounds = bounds;
          final top = (absTop[object] ?? 0) + bounds.top;
          final left = (absLeft[object] ?? 0) + bounds.left;
          absTop[object] = top;
          absLeft[object] = left;
          object.absBounds = HeapRect(top: top, left: left, bottom: top + bounds.height, right: left + bounds.width);
        }
      case HeapOpcode.caption:
        object.label ??= frame.text;
      case HeapOpcode.size:
        object.termCount++;
      case HeapOpcode.formatString:
        formatPayloads[object] ??= frame.payload;
      case HeapOpcode.stringTable:
        if (object.items.isEmpty) object.items = _parseEnumItems(frame.payload);
      case HeapOpcode.description:
        object.helpText ??= frame.descriptionText;
      case HeapOpcode.plotName:
        final text = frame.text ?? frame.path ?? frame.descriptionText;
        if (text != null && text.isNotEmpty) object.plotNames = [...object.plotNames, text];
      case HeapOpcode.path:
        if (object.objectClass == HeapObjectClass.bdCallLibrary) object.foreignLibraryPath ??= frame.path;
      case HeapOpcode.symbolName:
        if (object.objectClass == HeapObjectClass.bdCallLibrary) object.foreignEntryPoint ??= frame.text;
      default:
        break;
    }
  }

  void applyAttribute(ViHeapObject object, HeapAttr attr) {
    final objectClass = object.objectClass;
    switch (attr.attribute) {
      case HeapAttribute.stdNumMin:
        if (kControlTerminalClasses.contains(objectClass)) object.controlMin ??= attr.asDouble;
      case HeapAttribute.stdNumMax:
        if (kControlTerminalClasses.contains(objectClass)) object.controlMax ??= attr.asDouble;
      case HeapAttribute.constValue:
        final text = attr.asString;
        if (text != null && text.isNotEmpty) object.constText ??= text;
        if (objectClass == HeapObjectClass.bdConstDco && object.constValueRaw == null) {
          object.constValueRaw = _attrFlatBytes(attr);
          object.constValueScalar = attr.width.scalarBytes != null;
        }
      case HeapAttribute.shortText:
        final text = attr.asciiText;
        if (text != null && text.length == attr.width.scalarBytes) object.label ??= text;
      case HeapAttribute.formatStyle:
        final bytes = _attrFlatBytes(attr);
        if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every(_isPrintableAscii)) {
          object.displayFormat ??= String.fromCharCodes(bytes);
        }
      case HeapAttribute.cosmColorB:
        if (objectClass == HeapObjectClass.controlLabel) object.labelModeWord ??= attr.asInt;
      case HeapAttribute.termBounds:
        object.termBounds ??= attr.asRect;
      case HeapAttribute.termBMPs:
        object.termBmp ??= attr.asInt;
      case HeapAttribute.typeDescIndex:
        object.typeDescIdx ??= attr.asInt;
      case HeapAttribute.objFlags:
        object.objFlags ??= attr.asInt;
      case HeapAttribute.primResID:
        if (objectClass == HeapObjectClass.bdNode && attr.width == HeapAttrWidth.u16) object.primResId ??= attr.asInt;
      case HeapAttribute.dIdx:
        if (kMultiFrameStructureClasses.contains(objectClass)) object.dIdx ??= attr.asInt;
      case HeapAttribute.compressedWireTable:
        if (objectClass == HeapObjectClass.signal) object.wireTableRaw ??= _attrFlatBytes(attr);
      case HeapAttribute.selectDefaultCase:
        final frame = attr.asInt;
        if (objectClass == HeapObjectClass.bdStructureFrame && frame != null && frame != kViNoDefaultFrame) {
          object.defaultFrameIndex ??= frame;
        }
      case HeapAttribute.lastSignalKind:
        final word = attr.asInt;
        if (objectClass == HeapObjectClass.signal && word != null && word <= 0xffff) object.lastSignalKind ??= word;
      case HeapAttribute.backgroundColor:
        object.bgRgb ??= _opaqueRgb(attr);
      case HeapAttribute.fgColor:
        object.fgRgb ??= _opaqueRgb(attr);
      case HeapAttribute.contentColor:
        object.contentRgb ??= _opaqueRgb(attr);
      case HeapAttribute.structColor:
        object.structRgb ??= _opaqueRgb(attr);
      case HeapAttribute.borderColor:
        object.borderRgb ??= _opaqueRgb(attr);
      case HeapAttribute.plotColor:
        final rgb = _opaqueRgb(attr);
        if (rgb != null) object.plotColors = [...object.plotColors, rgb];
      default:
        break;
    }
  }
}

bool _isPrintableAscii(int byte) => byte >= 0x20 && byte < 0x7f;

int? _opaqueRgb(HeapAttr attr) {
  final rawColor = attr.kind == HeapAttrKind.color && attr.value is int ? attr.value as int : null;
  return attr.isTransparent || rawColor == 0x1 ? null : attr.rgb;
}

ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb', String? version}) {
  final build = _DiagramBuild(body, sectionTag);
  walkHeapObjects<ViHeapObject>(
    body,
    onGroupOpen: build.groupOpened,
    onGroupClose: (groupTag, object) => build.groupClosed(),
    onObjectOpen: build.objectOpened,
    onRecord: build.record,
  );
  final objects = build.objects;
  final kids = _childrenByParentOid(objects);
  final byOid = {for (final object in objects) object.oid: object};
  _placeLabels(objects, build.liveParent);
  _alignSequenceFrames(objects, kids);
  for (final object in objects) {
    object.category = classifyObject(objectClass: object.objectClass, termCount: object.termCount);
    object.typeKind = inferTypeKind(build.c4ops[object] ?? const <int>{}, build.formatPayloads[object]);
  }
  _inheritEnumItems(objects, byOid);
  _liftHelpText(objects, byOid);
  _promoteFramedNodes(objects, byOid, kids);
  _captionNodesFromLabels(objects, kids);
  _reanchorScrolledControls(objects, byOid, kids);
  return ViDiagram(sectionTag: sectionTag, objects: objects, version: version);
}

void _placeLabels(List<ViHeapObject> objects, Map<ViHeapObject, ViHeapObject?> liveParent) {
  for (final object in objects) {
    if (object.objectClass != HeapObjectClass.controlLabel) continue;
    final parent = liveParent[object];
    final local = object.bounds;
    final ownerAbs = parent?.absBounds;
    if (local == null || parent?.bounds == null || ownerAbs == null) continue;
    object.absBounds = HeapRect(
      top: ownerAbs.top + local.top,
      left: ownerAbs.left + local.left,
      bottom: ownerAbs.top + local.top + local.height,
      right: ownerAbs.left + local.left + local.width,
    );
  }
}

void _alignSequenceFrames(List<ViHeapObject> objects, Map<int, List<ViHeapObject>> kids) {
  for (final sequence in objects) {
    final sequenceAbs = sequence.absBounds;
    if (sequence.objectClass != HeapObjectClass.bdFlatSequence || sequenceAbs == null) continue;
    for (final frame in kids[sequence.oid] ?? const <ViHeapObject>[]) {
      final local = frame.bounds;
      final abs = frame.absBounds;
      if (frame.objectClass != HeapObjectClass.bdSequenceFrame || local == null || abs == null) continue;
      _shiftSubtree(frame, sequenceAbs.top + local.top - abs.top, sequenceAbs.left + local.left - abs.left, kids);
    }
  }
}

void _shiftSubtree(ViHeapObject root, int dTop, int dLeft, Map<int, List<ViHeapObject>> kids) {
  if (dTop == 0 && dLeft == 0) return;
  final expanded = <int>{};
  final work = <ViHeapObject>[root];
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
    if (expanded.add(object.oid)) work.addAll(kids[object.oid] ?? const <ViHeapObject>[]);
  }
}

void _inheritEnumItems(List<ViHeapObject> objects, Map<int, ViHeapObject> byOid) {
  for (final object in objects) {
    if (object.items.isEmpty) continue;
    var parentOid = object.parentOid;
    for (var depth = 0; parentOid != null && depth < _ancestorSearchDepth; depth++) {
      final parent = byOid[parentOid];
      if (parent == null) break;
      if (kControlTerminalClasses.contains(parent.objectClass)) {
        if (parent.items.isEmpty) parent.items = object.items;
        break;
      }
      parentOid = parent.parentOid;
    }
  }
}

void _liftHelpText(List<ViHeapObject> objects, Map<int, ViHeapObject> byOid) {
  for (final object in objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object.absBounds != null) continue;
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null && seen.add(parentOid)) {
      final parent = byOid[parentOid];
      if (parent == null) break;
      if (parent.absBounds != null) {
        parent.helpText ??= helpText;
        break;
      }
      parentOid = parent.parentOid;
    }
  }
}

void _promoteFramedNodes(List<ViHeapObject> objects, Map<int, ViHeapObject> byOid, Map<int, List<ViHeapObject>> kids) {
  for (final object in objects) {
    if (object.category != ViObjectKind.unknown) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (bounds.width * bounds.height >= _structureAreaCap) continue;
    if (object.parentOid == null || byOid[object.parentOid]?.kind != kViFrameCode) continue;
    final children = kids[object.oid];
    if (children == null) continue;
    final hasEndpoint = children.any((child) => child.kind == kNodeEndpointDcoKind);
    final hasConnector = children.any((child) => child.objectClass == HeapObjectClass.connectorTerminal);
    if (hasEndpoint && !hasConnector) object.category = ViObjectKind.node;
  }
}

void _captionNodesFromLabels(List<ViHeapObject> objects, Map<int, List<ViHeapObject>> kids) {
  for (final object in objects) {
    if (object.category != ViObjectKind.node || object.label != null) continue;
    for (final child in kids[object.oid] ?? const <ViHeapObject>[]) {
      final caption = child.objectClass == HeapObjectClass.controlLabel ? child.label?.trim() : null;
      if (caption != null && caption.isNotEmpty) {
        object.label = caption;
        break;
      }
    }
  }
}

List<String> _parseEnumItems(List<int> payload) {
  final items = <String>[];
  var offset = 0;
  while (offset < payload.length) {
    final length = payload[offset++];
    if (length == 0) continue;
    if (offset + length > payload.length) return const [];
    final text = String.fromCharCodes(payload.sublist(offset, offset + length));
    offset += length;
    if (!text.codeUnits.every(_isPrintableAscii)) return const [];
    items.add(text);
  }
  return items;
}

void _reanchorScrolledControls(
  List<ViHeapObject> objects,
  Map<int, ViHeapObject> byOid,
  Map<int, List<ViHeapObject>> kids,
) {
  int? viewportOf(ViHeapObject object) {
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null) {
      if (!seen.add(parentOid)) return null;
      final parent = byOid[parentOid];
      if (parent == null) return null;
      if (parent.objectClass == HeapObjectClass.contentViewport) return parent.oid;
      if (kControlTerminalClasses.contains(parent.objectClass) || parent.bounds != null) return null;
      parentOid = parent.parentOid;
    }
    return null;
  }

  final controlsByViewport = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (!kControlTerminalClasses.contains(object.objectClass) || object.bounds == null || object.absBounds == null) {
      continue;
    }
    final viewportOid = viewportOf(object);
    if (viewportOid != null) (controlsByViewport[viewportOid] ??= <ViHeapObject>[]).add(object);
  }

  for (final MapEntry(key: viewportOid, value: controls) in controlsByViewport.entries) {
    final viewportAbs = byOid[viewportOid]?.absBounds;
    if (viewportAbs == null) continue;
    final minTop = controls.map((control) => control.bounds!.top).reduce(min);
    final minLeft = controls.map((control) => control.bounds!.left).reduce(min);
    for (final control in controls) {
      final newTop = viewportAbs.top + (control.bounds!.top - minTop);
      final newLeft = viewportAbs.left + (control.bounds!.left - minLeft);
      _shiftSubtree(control, newTop - control.absBounds!.top, newLeft - control.absBounds!.left, kids);
    }
  }
}
