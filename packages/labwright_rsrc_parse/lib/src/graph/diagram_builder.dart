part of '../graph.dart';

final Set<int> kViSelectorGroupTags = {
  HeapGroupTag.selectorRangeList.tag,
  HeapGroupTag.selectorRangeListAlt.tag,
  HeapGroupTag.selectorStringPool.tag,
};

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
  if (value == null) return null;
  final bytes = switch (attr!.width) {
    HeapAttrWidth.u8 => 1,
    HeapAttrWidth.u16 => 2,
    HeapAttrWidth.u24 => 3,
    HeapAttrWidth.rgb => 4,
    _ => 0,
  };
  final chars = [for (var i = bytes - 1; i >= 0; i--) (value >> (8 * i)) & 0xff];
  return String.fromCharCodes(chars.skipWhile((char) => char == 0));
}

const _objAttrIds = {
  0x20, 0x21, 0x6c, 0x24, 0x28, 0x6f, 0x19, 0x2b, 0x2a, 0x29, 0x3a, 0xcb, 0xea, 0xe7, 0x4d, 0x9f, 0x22, 0x74, //
  0x54,
};

const int _structureAreaCap = 20000;

int? _attrScalarBytes(HeapAttrWidth width) => switch (width) {
  HeapAttrWidth.flag => 0,
  HeapAttrWidth.u8 => 1,
  HeapAttrWidth.u16 => 2,
  HeapAttrWidth.u24 => 3,
  HeapAttrWidth.rgb => 4,
  _ => null,
};

Uint8List? _attrFlatBytes(HeapAttr record) {
  final raw = record.rawValueBytes;
  if (raw != null) return raw;
  final scalarBytes = _attrScalarBytes(record.width);
  final value = record.asInt;
  if (scalarBytes == null || scalarBytes == 0 || value == null) return null;
  final out = Uint8List(scalarBytes);
  for (var i = 0; i < scalarBytes; i++) {
    out[i] = (value >> (8 * (scalarBytes - 1 - i))) & 0xff;
  }
  return out;
}

ViDiagram buildDiagram(Uint8List body, {String sectionTag = 'BDHb', String? version}) {
  final objects = <ViHeapObject>[];
  final c4ops = <ViHeapObject, Set<int>>{};
  final formatPayloads = <ViHeapObject, List<int>>{};
  final absTop = <ViHeapObject, int>{};
  final absLeft = <ViHeapObject, int>{};
  final liveParent = <ViHeapObject, ViHeapObject?>{};
  final length = body.length;

  ViHeapObject? styleRunOwner;
  var styleRunGroupDepth = 0;
  var styleRunStart = 0;
  var styleRunFontId = 0;
  var styleRunOpen = false;
  var styleRuns = <({int start, int fontId})>[];

  ViHeapObject? arrayIndexOwner;
  var arrayIndexGroupDepth = 0;

  ViHeapObject? selectorOwner;
  var selectorGroupDepth = 0;
  var selectorInPool = false;
  var selectorEntryOpen = false;
  var selectorRanges = <ViSelectorRange>[];
  var selectorStrings = <String>[];
  var entryLow = 0, entryHigh = 0, entryLowBound = 0, entryHighBound = 0, entryFrame = 0;

  walkHeapObjects<ViHeapObject>(
    body,
    onGroupOpen: (groupTag, cur) {
      if (selectorOwner != null) {
        selectorGroupDepth++;
        if (groupTag == HeapGroupTag.selectorRange.tag && selectorGroupDepth == 2 && !selectorInPool) {
          selectorEntryOpen = true;
          entryLow = entryHigh = entryLowBound = entryHighBound = entryFrame = 0;
        }
      } else if (cur != null && cur.objectClass == HeapObjectClass.bdStructureFrame) {
        if (kViSelectorGroupTags.contains(groupTag)) {
          selectorOwner = cur;
          selectorGroupDepth = 1;
          selectorInPool = groupTag == HeapGroupTag.selectorStringPool.tag;
          if (selectorInPool) {
            selectorStrings = <String>[];
          } else {
            selectorRanges = <ViSelectorRange>[];
          }
        }
      }
      if (arrayIndexOwner != null) {
        arrayIndexGroupDepth++;
      } else if (groupTag == HeapGroupTag.arrayIndex.tag &&
          cur != null &&
          cur.objectClass == HeapObjectClass.caseOrSequence) {
        arrayIndexOwner = cur;
        arrayIndexGroupDepth = 1;
      }
      if (styleRunOwner == null) {
        if (groupTag == HeapGroupTag.fontRunList.tag && cur != null) {
          styleRunOwner = cur;
          styleRunGroupDepth = 1;
          styleRuns = [];
        }
        return;
      }
      styleRunGroupDepth++;
      if (groupTag == HeapGroupTag.fontRun.tag && styleRunGroupDepth == 2) {
        styleRunOpen = true;
        styleRunStart = 0;
        styleRunFontId = 0;
      }
    },
    onGroupClose: (groupTag, cur) {
      if (selectorOwner != null) {
        if (selectorEntryOpen && selectorGroupDepth == 2) {
          selectorRanges.add(
            ViSelectorRange(
              low: entryLow,
              high: entryHigh,
              lowBound: ViSelectorBound.ofCode(entryLowBound),
              highBound: ViSelectorBound.ofCode(entryHighBound),
              frame: entryFrame,
            ),
          );
          selectorEntryOpen = false;
        }
        if (--selectorGroupDepth == 0) {
          if (selectorInPool) {
            if (selectorOwner!.selectorStrings.isEmpty) selectorOwner!.selectorStrings = selectorStrings;
          } else if (selectorOwner!.selectorRanges.isEmpty) {
            selectorOwner!.selectorRanges = selectorRanges;
          }
          selectorOwner = null;
          selectorInPool = false;
        }
      }
      if (arrayIndexOwner != null && --arrayIndexGroupDepth == 0) {
        arrayIndexOwner = null;
      }
      if (styleRunOwner == null) return;
      styleRunGroupDepth--;
      if (styleRunOpen && styleRunGroupDepth == 1) {
        styleRuns.add((start: styleRunStart, fontId: styleRunFontId));
        styleRunOpen = false;
      }
      if (styleRunGroupDepth == 0) {
        if (styleRuns.isNotEmpty && styleRunOwner!.textStyleRuns.isEmpty) {
          styleRunOwner!.textStyleRuns = styleRuns;
        }
        styleRunOwner = null;
      }
    },
    onObjectOpen: (span, kind, oid, parent) {
      final cur = ViHeapObject(oid: oid, kind: kind, offset: span.offset);
      cur.parentOid = parent?.oid;
      liveParent[cur] = parent;
      absTop[cur] = absTop[parent] ?? 0;
      absLeft[cur] = absLeft[parent] ?? 0;
      objects.add(cur);
      c4ops[cur] = <int>{};
      return cur;
    },
    onRecord: (span, cur) {
      if (cur == null) return;
      final offset = span.offset;
      final lead = span.lead;
      if (selectorOwner != null && identical(cur, selectorOwner)) {
        if (selectorInPool) {
          final value = _selectorPoolString(body, offset, lead, span.length);
          if (value != null) {
            selectorStrings.add(value);
            return;
          }
        } else if (selectorEntryOpen) {
          final attr = decodeHeapAttr(body, offset);
          final value = attr?.asInt;
          if (value != null) {
            final tag = attr!.rawTag;
            if (tag == SelectorRangeAttr.low.raw) {
              entryLow = _signedAtWidth(value, attr.width);
              return;
            }
            if (tag == SelectorRangeAttr.high.raw) {
              entryHigh = _signedAtWidth(value, attr.width);
              return;
            }
            if (tag == SelectorRangeAttr.lowBound.raw) {
              entryLowBound = value;
              return;
            }
            if (tag == SelectorRangeAttr.highBound.raw) {
              entryHighBound = value;
              return;
            }
            if (tag == SelectorRangeAttr.frame.raw) {
              entryFrame = value;
              return;
            }
          }
        }
      }
      if (arrayIndexOwner != null && identical(cur, arrayIndexOwner)) {
        final attr = decodeHeapAttr(body, offset);
        final value = attr?.asInt;
        if (value != null && attr!.rawTag == HeapAttribute.arrayElemValue.raw) {
          arrayIndexOwner!.arrayIndex = value;
          return;
        }
      }
      if (styleRunOpen && identical(cur, styleRunOwner)) {
        final attr = decodeHeapAttr(body, offset);
        final value = attr?.asInt;
        if (value != null) {
          if (attr!.rawTag == FontRunAttr.start.raw) {
            styleRunStart = value;
            return;
          }
          if (attr.rawTag == FontRunAttr.fontId.raw) {
            styleRunFontId = value;
            return;
          }
        }
      }
      if (lead == kHeapRecordPrefix) {
        final rec = c4FrameAt(body, offset, sectionTag);
        if (rec == null) return;
        c4ops[cur]!.add(rec.opcode);
        switch (rec.opcode) {
          case 0x2d:
            if (cur.bounds == null && rec.bounds != null) {
              final bounds = rec.bounds!;
              cur.bounds = bounds;
              final top = (absTop[cur] ?? 0) + bounds.top;
              final left = (absLeft[cur] ?? 0) + bounds.left;
              absTop[cur] = top;
              absLeft[cur] = left;
              cur.absBounds = HeapRect(top: top, left: left, bottom: top + bounds.height, right: left + bounds.width);
            }
          case 0x22:
            cur.label ??= rec.text;
          case 0x1f:
            cur.termCount++;
          case 0x74:
            formatPayloads[cur] ??= rec.payload;
          case 0x2e:
            if (cur.items.isEmpty) cur.items = _parseEnumItems(rec.payload);
          case 0x19:
            cur.helpText ??= rec.descriptionText;
          case 0x27:
            {
              final text = rec.text ?? rec.path ?? rec.descriptionText;
              if (text != null && text.isNotEmpty) cur.plotNames = [...cur.plotNames, text];
            }
          case 0xa4:
            if (cur.objectClass == HeapObjectClass.bdCallLibrary) cur.foreignLibraryPath ??= rec.path;
          case 0xc4:
            if (cur.objectClass == HeapObjectClass.bdCallLibrary) cur.foreignEntryPoint ??= rec.text;
        }
      } else if (lead == 0x14) {
        final ref = decodeHeapRef(body, offset);
        if (ref != null) {
          (cur.typedRefs[ref.kind] ??= <int>[]).add(ref.targetOid);
          if (ref.kind == HeapRefKind.childRef) cur.refs.add(ref.targetOid);
        }
      } else if (offset + 1 < length && _objAttrIds.contains(body[offset + 1])) {
        final attr = decodeHeapAttr(body, offset);
        if (attr == null) return;
        final number = attr.asDouble;
        if (number != null && kControlTerminalClasses.contains(cur.objectClass)) {
          if (attr.attribute == HeapAttribute.stdNumMin) cur.controlMin ??= number;
          if (attr.attribute == HeapAttribute.stdNumMax) cur.controlMax ??= number;
        }
        if (attr.attribute == HeapAttribute.constValue) {
          final text = attr.asString;
          if (text != null && text.isNotEmpty) cur.constText ??= text;
        }
        if (attr.attribute == HeapAttribute.shortText) {
          final text = attr.asciiText;
          if (text != null && text.length == _attrScalarBytes(attr.width)) {
            cur.label ??= text;
          }
        }
        if (attr.attribute == HeapAttribute.constValue &&
            cur.objectClass == HeapObjectClass.bdConstDco &&
            cur.constValueRaw == null) {
          cur.constValueRaw = _attrFlatBytes(attr);
          cur.constValueScalar = _attrScalarBytes(attr.width) != null;
        }
        if (attr.attribute == HeapAttribute.formatStyle) {
          final bytes = _attrFlatBytes(attr);
          if (bytes != null && bytes.isNotEmpty && bytes.first == 0x25 && bytes.every((b) => b >= 0x20 && b < 0x7f)) {
            cur.displayFormat ??= String.fromCharCodes(bytes);
          }
        }
        if (attr.attribute == HeapAttribute.cosmColorB && cur.objectClass == HeapObjectClass.controlLabel) {
          cur.labelModeWord ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.termBounds) cur.termBounds ??= attr.asRect;
        if (attr.attribute == HeapAttribute.termBMPs) cur.termBmp ??= attr.asInt;
        if (attr.attribute == HeapAttribute.typeDescIndex) cur.typeDescIdx ??= attr.asInt;
        if (attr.attribute == HeapAttribute.objFlags) cur.objFlags ??= attr.asInt;
        if (attr.attribute == HeapAttribute.primResID &&
            cur.objectClass == HeapObjectClass.bdNode &&
            attr.width == HeapAttrWidth.u16) {
          cur.primResId ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.dIdx && kMultiFrameStructureClasses.contains(cur.objectClass)) {
          cur.dIdx ??= attr.asInt;
        }
        if (attr.attribute == HeapAttribute.compressedWireTable && cur.objectClass == HeapObjectClass.signal) {
          if (attr.width == HeapAttrWidth.container) {
            cur.wireTableRaw ??= attr.rawValueBytes;
          } else {
            final scalarBytes = _attrScalarBytes(attr.width);
            final value = attr.asInt;
            if (scalarBytes != null && scalarBytes > 0 && value != null) {
              final table = Uint8List(scalarBytes);
              for (var b = 0; b < scalarBytes; b++) {
                table[b] = (value >> (8 * (scalarBytes - 1 - b))) & 0xff;
              }
              cur.wireTableRaw ??= table;
            }
          }
        }
        if (attr.attribute == HeapAttribute.selectDefaultCase && cur.objectClass == HeapObjectClass.bdStructureFrame) {
          final frame = attr.asInt;
          if (frame != null && frame != kViNoDefaultFrame) cur.defaultFrameIndex ??= frame;
        }
        if (attr.attribute == HeapAttribute.lastSignalKind && cur.objectClass == HeapObjectClass.signal) {
          final word = attr.asInt;
          if (word != null && word <= 0xffff) cur.lastSignalKind ??= word;
        }
        final rawColor = attr.kind == HeapAttrKind.color && attr.value is int ? attr.value as int : null;
        final rgb = attr.isTransparent || rawColor == 0x1 ? null : attr.rgb;
        if (rgb != null) {
          switch (attr.attribute) {
            case HeapAttribute.backgroundColor:
              cur.bgRgb ??= rgb;
            case HeapAttribute.fgColor:
              cur.fgRgb ??= rgb;
            case HeapAttribute.contentColor:
              cur.contentRgb ??= rgb;
            case HeapAttribute.structColor:
              cur.structRgb ??= rgb;
            case HeapAttribute.borderColor:
              cur.borderRgb ??= rgb;
            case HeapAttribute.plotColor:
              (cur.plotColors.isEmpty ? (cur.plotColors = <int>[]) : cur.plotColors).add(rgb);
            default:
              break;
          }
        }
      }
    },
  );

  for (final object in objects) {
    if (object.objectClass != HeapObjectClass.controlLabel) continue;
    final parent = liveParent[object];
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

  final childrenOf = <ViHeapObject, List<ViHeapObject>>{};
  for (final object in objects) {
    final parent = liveParent[object];
    if (parent != null) (childrenOf[parent] ??= []).add(object);
  }
  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    final b = root.absBounds;
    if (b != null) {
      root.absBounds = HeapRect(
        top: b.top + dTop,
        left: b.left + dLeft,
        bottom: b.bottom + dTop,
        right: b.right + dLeft,
      );
    }
    for (final child in childrenOf[root] ?? const <ViHeapObject>[]) {
      shiftSubtree(child, dTop, dLeft);
    }
  }

  for (final object in objects) {
    if (object.objectClass != HeapObjectClass.bdFlatSequence || object.absBounds == null) continue;
    for (final frame in childrenOf[object] ?? const <ViHeapObject>[]) {
      final local = frame.bounds;
      final abs = frame.absBounds;
      if (frame.objectClass != HeapObjectClass.bdSequenceFrame || local == null || abs == null) continue;
      final dTop = object.absBounds!.top + local.top - abs.top;
      final dLeft = object.absBounds!.left + local.left - abs.left;
      if (dTop != 0 || dLeft != 0) shiftSubtree(frame, dTop, dLeft);
    }
  }

  for (final object in objects) {
    object.category = classifyObject(objectClass: object.objectClass, termCount: object.termCount);
    object.typeKind = inferTypeKind(c4ops[object] ?? const <int>{}, formatPayloads[object]);
  }

  final byOid = {for (final object in objects) object.oid: object};
  for (final object in objects) {
    if (object.items.isEmpty) continue;
    var parentOid = object.parentOid;
    var depth = 0;
    while (parentOid != null && depth < 12) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (kControlTerminalClasses.contains(po.objectClass)) {
        if (po.items.isEmpty) po.items = object.items;
        break;
      }
      parentOid = po.parentOid;
      depth++;
    }
  }

  for (final object in objects) {
    final helpText = object.helpText;
    if (helpText == null || helpText.isEmpty || object.absBounds != null) continue;
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null && seen.add(parentOid)) {
      final po = byOid[parentOid];
      if (po == null) break;
      if (po.absBounds != null) {
        po.helpText ??= helpText;
        break;
      }
      parentOid = po.parentOid;
    }
  }

  final nodeKids = _childrenByParentOid(objects);

  for (final object in objects) {
    if (object.category != ViObjectKind.unknown) continue;
    final bounds = object.absBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
    if (bounds.width * bounds.height >= _structureAreaCap) continue;
    if (object.parentOid == null || byOid[object.parentOid]?.kind != kViFrameCode) continue;
    final cs = nodeKids[object.oid];
    if (cs == null) continue;
    final hasStructural = cs.any((c) => c.kind == kNodeEndpointDcoKind);
    final hasConnector = cs.any((c) => c.objectClass == HeapObjectClass.connectorTerminal);
    if (!hasStructural || hasConnector) continue;
    object.category = ViObjectKind.node;
  }

  for (final object in objects) {
    if (object.category != ViObjectKind.node || object.label != null) continue;
    final caps = (nodeKids[object.oid] ?? const <ViHeapObject>[])
        .where((c) => c.objectClass == HeapObjectClass.controlLabel)
        .map((c) => c.label?.trim())
        .where((cap) => cap != null && cap.isNotEmpty);
    if (caps.isNotEmpty) object.label = caps.first;
  }

  _reanchorScrolledControls(objects, byOid, nodeKids);
  return ViDiagram(sectionTag: sectionTag, objects: objects, version: version);
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

void _reanchorScrolledControls(
  List<ViHeapObject> objects,
  Map<int, ViHeapObject> byOid,
  Map<int, List<ViHeapObject>> kids,
) {
  int? reanchorViewport(ViHeapObject object) {
    var parentOid = object.parentOid;
    final seen = <int>{};
    while (parentOid != null) {
      if (!seen.add(parentOid)) return null;
      final po = byOid[parentOid];
      if (po == null) return null;
      if (po.objectClass == HeapObjectClass.contentViewport) return po.oid;
      if (kControlTerminalClasses.contains(po.objectClass) || po.bounds != null) return null;
      parentOid = po.parentOid;
    }
    return null;
  }

  final groups = <int, List<ViHeapObject>>{};
  for (final object in objects) {
    if (!kControlTerminalClasses.contains(object.objectClass) || object.bounds == null || object.absBounds == null) {
      continue;
    }
    final viewport = reanchorViewport(object);
    if (viewport != null) (groups[viewport] ??= <ViHeapObject>[]).add(object);
  }

  void shiftSubtree(ViHeapObject root, int dTop, int dLeft) {
    if (dTop == 0 && dLeft == 0) return;
    final seen = <ViHeapObject>{root};
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
      if (!expanded.add(object.oid)) continue;
      final cs = kids[object.oid];
      if (cs != null) {
        for (final child in cs) {
          if (seen.add(child)) work.add(child);
        }
      }
    }
  }

  for (final MapEntry(key: vOid, value: controls) in groups.entries) {
    final viewport = byOid[vOid];
    if (viewport?.absBounds == null) continue;
    final minTop = controls.map((c) => c.bounds!.top).reduce(min);
    final minLeft = controls.map((c) => c.bounds!.left).reduce(min);
    for (final control in controls) {
      final newTop = viewport!.absBounds!.top + (control.bounds!.top - minTop);
      final newLeft = viewport.absBounds!.left + (control.bounds!.left - minLeft);
      shiftSubtree(control, newTop - control.absBounds!.top, newLeft - control.absBounds!.left);
    }
  }
}
