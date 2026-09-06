library;

import 'dart:typed_data';

import 'blocks/compiled_code.dart' show compiledCodeFrames, reserializeCompiledCode;
import 'blocks/dfds.dart' show DfdsContext, dataSpaceFrames, reserializeDataSpace;
import 'blocks/type_map.dart' show reserializeTypeMap, typeMapFrames;
import 'blocks/type_pool.dart' show reserializeTypePool, typePoolFrames;
import 'heap.dart';

class HeapWriteResult {
  HeapWriteResult({
    required this.bytes,
    required this.modelBytes,
    required this.copiedBytes,
    required this.modelBugs,
  });

  final Uint8List bytes;

  final int modelBytes;

  final int copiedBytes;

  final int modelBugs;

  int get bodyBytes => modelBytes + copiedBytes;
}

void _putU16(Uint8List b, int at, int v) {
  b[at] = (v >> 8) & 0xff;
  b[at + 1] = v & 0xff;
}

void _putS16(Uint8List b, int at, int v) {
  b[at] = (v >> 8) & 0xff;
  b[at + 1] = v & 0xff;
}

void _putU32(Uint8List b, int at, int v) {
  b[at] = (v >> 24) & 0xff;
  b[at + 1] = (v >> 16) & 0xff;
  b[at + 2] = (v >> 8) & 0xff;
  b[at + 3] = v & 0xff;
}

class _Modeled {
  const _Modeled(this.prefix, this.length, {this.expected = false, this.retained = 0});

  final Uint8List? prefix;

  final int length;

  final bool expected;

  final int retained;
}

const _Modeled _nothing = _Modeled(null, 0);

bool _c4RetainsInterior(HeapShape shape) => switch (shape) {
  HeapShape.string || HeapShape.stringTable || HeapShape.helpText || HeapShape.path || HeapShape.container => true,
  HeapShape.rectangle || HeapShape.none => false,
};

_Modeled _modelRecord(Uint8List body, int offset, int lead, int spanLength) {
  final header = heapObjectHeaderAt(body, offset);
  if (header != null) {
    if (header.length == 13) {
      final out = Uint8List(13);
      out[0] = body[offset];
      out[1] = body[offset + 1];
      out[2] = 0x02;
      out[3] = 0xfe;
      _putU16(out, 4, header.kind);
      out[6] = 0xfd;
      out[7] = 0x80;
      out[8] = 0x00;
      _putU32(out, 9, header.oid);
      return _Modeled(out, 13, expected: true);
    }
    final out = Uint8List(9);
    out[0] = body[offset];
    out[1] = body[offset + 1];
    out[2] = 0x02;
    out[3] = 0xfe;
    _putU16(out, 4, header.kind);
    out[6] = 0xfd;
    _putU16(out, 7, header.oid);
    return _Modeled(out, 9, expected: true);
  }

  final ref = decodeHeapRef(body, offset);
  if (ref != null) {
    if (ref.length == 10) {
      final out = Uint8List(10);
      out[0] = body[offset];
      out[1] = body[offset + 1];
      out[2] = 0x01;
      out[3] = 0xfd;
      out[4] = 0x80;
      out[5] = 0x00;
      _putU32(out, 6, ref.targetOid);
      return _Modeled(out, 10, expected: true);
    }
    final out = Uint8List(6);
    out[0] = body[offset];
    out[1] = body[offset + 1];
    out[2] = 0x01;
    out[3] = 0xfd;
    _putU16(out, 4, ref.targetOid);
    return _Modeled(out, 6, expected: true);
  }

  if (kHeapGroupCloseLeads.contains(lead) && spanLength == 2) {
    return _Modeled(Uint8List.fromList([body[offset], body[offset + 1]]), 2, expected: true);
  }

  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(body, offset, '');
    if (rec != null) {
      final headerLen = rec.headerLength;
      if (rec.kind.shape == HeapShape.rectangle && rec.payload.length == 8) {
        final rect = HeapRect.fromPayload(rec.payload);
        if (rect != null) {
          final out = Uint8List(11);
          out[0] = kHeapRecordPrefix;
          out[1] = rec.opcode;
          out[2] = 0x08;
          _putS16(out, 3, rect.top);
          _putS16(out, 5, rect.left);
          _putS16(out, 7, rect.bottom);
          _putS16(out, 9, rect.right);
          return _Modeled(out, 11, expected: true);
        }
      }
      final out = Uint8List(headerLen);
      out[0] = kHeapRecordPrefix;
      out[1] = rec.opcode;
      if (headerLen == 5) {
        out[2] = 0xff;
        _putU16(out, 3, rec.payload.length);
      } else {
        out[2] = rec.payload.length;
      }
      final retained = _c4RetainsInterior(rec.kind.shape) ? rec.payload.length : 0;
      return _Modeled(out, headerLen, expected: true, retained: retained);
    }
    return _nothing;
  }

  final attr = decodeHeapAttr(body, offset);
  if (attr != null) {
    switch (attr.width) {
      case HeapAttrWidth.flag:
        return _Modeled(Uint8List.fromList([body[offset], body[offset + 1]]), 2, expected: true);
      case HeapAttrWidth.u8:
      case HeapAttrWidth.u16:
      case HeapAttrWidth.u24:
      case HeapAttrWidth.rgb:
        final value = attr.value;
        if (value is! int) return _nothing;
        final valueBytes = attr.length - 2;
        final out = Uint8List(attr.length);
        out[0] = body[offset];
        out[1] = body[offset + 1];
        for (var i = 0; i < valueBytes; i++) {
          out[2 + i] = (value >> (8 * (valueBytes - 1 - i))) & 0xff;
        }
        return _Modeled(out, attr.length, expected: true);
      case HeapAttrWidth.rect:
        final rect = attr.value;
        if (rect is! HeapRect) return _nothing;
        final out = Uint8List(11);
        out[0] = body[offset];
        out[1] = body[offset + 1];
        out[2] = 0x08;
        _putS16(out, 3, rect.top);
        _putS16(out, 5, rect.left);
        _putS16(out, 7, rect.bottom);
        _putS16(out, 9, rect.right);
        return _Modeled(out, 11, expected: true);
      case HeapAttrWidth.f64:
        return _Modeled(
          Uint8List.fromList([body[offset], body[offset + 1], 0x08]),
          3,
          expected: true,
          retained: 8,
        );
      case HeapAttrWidth.blob:
      case HeapAttrWidth.container:
        if (body[offset] == 0xc6 && offset + 2 < body.length && body[offset + 2] == 0xff) {
          final len = attr.length - 5;
          final out = Uint8List(5);
          out[0] = body[offset];
          out[1] = body[offset + 1];
          out[2] = 0xff;
          _putU16(out, 3, len);
          return _Modeled(out, 5, expected: true, retained: len);
        }
        return _Modeled(
          Uint8List.fromList([body[offset], body[offset + 1], attr.length - 3]),
          3,
          expected: true,
          retained: attr.length - 3,
        );
    }
  }

  if (kHeapGroupOpenLeads.contains(lead)) {
    if (spanLength >= 4 && isHeapTypeTag(body[offset + 3])) {
      return _Modeled(
        Uint8List.fromList([body[offset], body[offset + 1], body[offset + 2]]),
        3,
        expected: true,
        retained: spanLength - 3,
      );
    }
    if (spanLength == 2) {
      return _Modeled(Uint8List.fromList([body[offset], body[offset + 1]]), 2, expected: true);
    }
  }

  return _nothing;
}

class HeapContentSplit {
  const HeapContentSplit({required this.modelBytes, required this.copiedBytes, required this.modelBugs});

  final int modelBytes;
  final int copiedBytes;
  final int modelBugs;
}

HeapContentSplit attributeHeapBody(Uint8List body, [String? sectionTag, DfdsContext? dfdsContext]) {
  if (sectionTag == 'DFDS' && dfdsContext != null) {
    return dataSpaceFrames(body, dfdsContext)
        ? HeapContentSplit(modelBytes: body.length, copiedBytes: 0, modelBugs: 0)
        : HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (sectionTag == 'VCTP') {
    return typePoolFrames(body)
        ? HeapContentSplit(modelBytes: body.length, copiedBytes: 0, modelBugs: 0)
        : HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (sectionTag == 'VICD') {
    return compiledCodeFrames(body)
        ? HeapContentSplit(modelBytes: body.length, copiedBytes: 0, modelBugs: 0)
        : HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (sectionTag == 'TM80') {
    return typeMapFrames(body)
        ? HeapContentSplit(modelBytes: body.length, copiedBytes: 0, modelBugs: 0)
        : HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (body.length < 4) {
    return HeapContentSplit(modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  var model = 0;
  var copied = 4;
  var bugs = 0;
  final walk = walkHeapBody(body);
  for (final span in walk.spans) {
    final m = _modelRecord(body, span.offset, span.lead, span.length);
    final modelLen = _verifiedModelLength(body, span.offset, m);
    if (m.length > 0 && modelLen == 0 && m.expected) bugs++;
    model += modelLen;
    copied += span.length - modelLen;
  }
  final coveredEnd = 4 + walk.coveredBytes;
  if (coveredEnd < body.length) copied += body.length - coveredEnd;
  return HeapContentSplit(modelBytes: model, copiedBytes: copied, modelBugs: bugs);
}

int _verifiedModelLength(Uint8List body, int offset, _Modeled m) {
  final prefix = m.prefix;
  if (prefix == null || m.length == 0) return 0;
  for (var i = 0; i < m.length; i++) {
    if (prefix[i] != body[offset + i]) return 0;
  }
  return m.length + m.retained;
}

HeapWriteResult serializeHeapBody(Uint8List body, [String? sectionTag, DfdsContext? dfdsContext]) {
  if (sectionTag == 'DFDS' && dfdsContext != null) {
    final reserialized = reserializeDataSpace(body, dfdsContext);
    if (reserialized != null) {
      return HeapWriteResult(bytes: reserialized, modelBytes: body.length, copiedBytes: 0, modelBugs: 0);
    }
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (sectionTag == 'VCTP') {
    final reserialized = reserializeTypePool(body);
    if (reserialized != null) {
      return HeapWriteResult(bytes: reserialized, modelBytes: body.length, copiedBytes: 0, modelBugs: 0);
    }
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (sectionTag == 'VICD') {
    final reserialized = reserializeCompiledCode(body);
    if (reserialized != null) {
      return HeapWriteResult(bytes: reserialized, modelBytes: body.length, copiedBytes: 0, modelBugs: 0);
    }
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }
  if (sectionTag == 'TM80') {
    final reserialized = reserializeTypeMap(body);
    if (reserialized != null) {
      return HeapWriteResult(bytes: reserialized, modelBytes: body.length, copiedBytes: 0, modelBugs: 0);
    }
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }

  final out = BytesBuilder(copy: false);
  var model = 0;
  var copied = 0;
  var bugs = 0;

  if (body.length < 4) {
    out.add(body);
    return HeapWriteResult(bytes: body, modelBytes: 0, copiedBytes: body.length, modelBugs: 0);
  }

  out.add(Uint8List.sublistView(body, 0, 4));
  copied += 4;

  final walk = walkHeapBody(body);
  for (final span in walk.spans) {
    final offset = span.offset;
    final m = _modelRecord(body, offset, span.lead, span.length);
    final modelLen = _verifiedModelLength(body, offset, m);
    if (m.length > 0 && modelLen == 0 && m.expected) bugs++;

    if (modelLen > 0) {
      out.add(m.prefix!);
      if (m.retained > 0) {
        out.add(Uint8List.sublistView(body, offset + m.length, offset + m.length + m.retained));
      }
      model += modelLen;
    }
    final rest = span.length - modelLen;
    if (rest > 0) {
      out.add(Uint8List.sublistView(body, offset + modelLen, offset + span.length));
      copied += rest;
    }
  }

  final coveredEnd = 4 + walk.coveredBytes;
  if (coveredEnd < body.length) {
    out.add(Uint8List.sublistView(body, coveredEnd));
    copied += body.length - coveredEnd;
  }

  return HeapWriteResult(bytes: out.toBytes(), modelBytes: model, copiedBytes: copied, modelBugs: bugs);
}
