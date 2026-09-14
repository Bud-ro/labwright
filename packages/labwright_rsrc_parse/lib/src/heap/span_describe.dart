/// Names each framed span of a C4 record heap for display: the record family it belongs to,
/// a title, and its decoded value when the span carries one.
library;

import 'dart:typed_data';

import '../diagram/diagram.dart' show HeapObjectClass, ClassConfidence;
import 'heap.dart';

/// The record family a heap span belongs to.
enum HeapSpanKind {
  /// The four-byte length word before the records.
  header,

  /// An object header declaring an object id and class.
  objectOpen,

  /// A property token on the current object.
  property,

  /// A bracket-tree group open (lead `0x10`–`0x13` with a type tag at +3).
  groupOpen,

  /// A bracket-tree group close (lead `0x08`–`0x0b`).
  groupClose,

  /// A typed reference to another object.
  reference,

  /// A `c4` record whose payload is a rectangle.
  rectangle,

  /// A `c4` record or attribute whose payload is text.
  text,

  /// A `c4` container record or a length-prefixed container attribute.
  container,

  /// Any other `c4` record.
  record,

  /// A colour attribute.
  color,

  /// Any other attribute.
  attribute,

  /// A bare `04` token.
  typeToken,

  /// Bytes after the point where the walk stopped.
  unframed,

  /// A framed record of no decoded family.
  other,
}

/// The decoded value of a heap span, when it has one.
sealed class HeapSpanValue {
  const HeapSpanValue();
}

final class HeapRectValue extends HeapSpanValue {
  const HeapRectValue(this.rect);

  final HeapRect rect;
}

final class HeapTextValue extends HeapSpanValue {
  const HeapTextValue(this.text);

  final String text;
}

/// An RGB colour, or transparent when [rgb] is null.
final class HeapColorValue extends HeapSpanValue {
  const HeapColorValue(this.rgb);

  final int? rgb;
}

final class HeapNumberValue extends HeapSpanValue {
  const HeapNumberValue(this.value, this.width, {this.ascii});

  final int value;

  final HeapAttrWidth width;

  /// The value read as ASCII characters, for attributes that hold text in an integer.
  final String? ascii;
}

/// A byte count: the length word's value or the size of the unframed tail.
final class HeapByteCountValue extends HeapSpanValue {
  const HeapByteCountValue(this.bytes);

  final int bytes;
}

final class HeapDoubleValue extends HeapSpanValue {
  const HeapDoubleValue(this.value);

  final double value;
}

/// A named span of a heap body.
final class HeapSpanInfo {
  const HeapSpanInfo({
    required this.offset,
    required this.length,
    required this.lead,
    required this.kind,
    required this.title,
    this.detail = '',
    this.confidence,
    this.value,
  });

  final int offset;

  final int length;

  /// The span's first byte.
  final int lead;

  final HeapSpanKind kind;

  /// What the span is, e.g. `Object · Numeric control` or `c4 2d · bounds`.
  final String title;

  /// One sentence on the span's meaning, without its value.
  final String detail;

  /// How well the family's meaning is established, for tokens and attributes that state it.
  final String? confidence;

  final HeapSpanValue? value;
}

String _hex2(int value) => value.toRadixString(16).padLeft(2, '0');

/// Every span of a heap body: the length word, each walked record, and the unframed tail
/// where the walk stopped.
List<HeapSpanInfo> describeHeapBody(Uint8List body, String sectionTag) {
  final walk = walkHeapBody(body);
  final view = ByteData.sublistView(body);
  return [
    if (body.length >= 4)
      HeapSpanInfo(
        offset: 0,
        length: 4,
        lead: body[0],
        kind: HeapSpanKind.header,
        title: 'Heap content length (u32)',
        detail: 'Size of the record stream that follows, whose walk begins at offset 4:',
        value: HeapByteCountValue(view.getUint32(0)),
      ),
    for (final span in walk.spans) describeHeapSpan(body, span, sectionTag),
    if (walk.stoppedAtOffset case final stopped? when stopped < body.length)
      HeapSpanInfo(
        offset: stopped,
        length: body.length - stopped,
        lead: walk.stoppedLead ?? body[stopped],
        kind: HeapSpanKind.unframed,
        title: 'Unframed tail (lead 0x${(walk.stoppedLead ?? 0).toRadixString(16)})',
        detail: 'The record walk stopped here: this lead byte\'s record family is not yet decoded.',
        value: HeapByteCountValue(body.length - stopped),
      ),
  ];
}

/// Names one walked span.
HeapSpanInfo describeHeapSpan(Uint8List body, HeapSpan span, String sectionTag) {
  final offset = span.offset, lead = span.lead;
  HeapSpanInfo make(HeapSpanKind kind, String title, String detail, {String? confidence, HeapSpanValue? value}) =>
      HeapSpanInfo(
        offset: offset,
        length: span.length,
        lead: lead,
        kind: kind,
        title: title,
        detail: detail,
        confidence: confidence,
        value: value,
      );

  if (kHeapObjectHeaderLeads.contains(lead) &&
      offset + 9 <= body.length &&
      body[offset + 2] == 0x02 &&
      body[offset + 3] == 0xfe &&
      body[offset + 6] == 0xfd) {
    final view = ByteData.sublistView(body);
    final kind = view.getUint16(offset + 4);
    final oid = view.getUint16(offset + 7);
    final cls = HeapObjectClass.fromCode(kind);
    return make(
      HeapSpanKind.objectOpen,
      'Object · ${cls.label}',
      'Declares object #$oid of class 0x${kind.toRadixString(16)}.',
      confidence: cls.confidence == ClassConfidence.confirmed ? null : cls.confidence.name,
      value: HeapNumberValue(oid, HeapAttrWidth.u16),
    );
  }
  final prop = decodeHeapPropertyToken(body, offset);
  if (prop != null) {
    final token = prop.token;
    return make(
      HeapSpanKind.property,
      '${_hex2(lead)} ${_hex2(body[offset + 1])} · ${token.tokenName}',
      'Object property.',
      confidence: token.confidence == AttrConfidence.confirmed ? null : token.confidence.name,
      value: prop.value == null ? null : HeapNumberValue(prop.value!, HeapAttrWidth.u8),
    );
  }
  if (kHeapGroupOpenLeads.contains(lead) && offset + 3 < body.length && isHeapTypeTag(body[offset + 3])) {
    return make(
      HeapSpanKind.groupOpen,
      'Group open · tag 0x${_hex2(body[offset + 1])}',
      'Opens a bracket-tree group; the type tag at +3 distinguishes it from a property token. '
          'Its close carries lead 0x${_hex2(lead - 0x08)} and the same tag.',
    );
  }
  if (kHeapGroupCloseLeads.contains(lead)) {
    final tag = offset + 1 < body.length ? body[offset + 1] : -1;
    return make(
      HeapSpanKind.groupClose,
      'Group close · tag 0x${_hex2(tag)}',
      'Closes the group opened with lead 0x${_hex2(lead + 0x08)} and the same tag.',
    );
  }
  final ref = decodeHeapRef(body, offset);
  if (ref != null) {
    return make(
      HeapSpanKind.reference,
      '${ref.kind.refName} → #${ref.targetOid}',
      'A typed reference to another object.',
      confidence: ref.kind.confidence == AttrConfidence.confirmed ? null : ref.kind.confidence.name,
      value: HeapNumberValue(ref.targetOid, HeapAttrWidth.u16),
    );
  }
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(body, offset, sectionTag);
    if (rec != null) {
      final opcode = rec.kind;
      final hexop = 'C4 ${_hex2(rec.opcode)}';
      final rect = rec.rect;
      if (rect != null) {
        return make(
          HeapSpanKind.rectangle,
          '$hexop · ${opcode.name}',
          'Rectangle (4× s16).',
          value: HeapRectValue(rect),
        );
      }
      final text = rec.text ?? rec.descriptionText ?? rec.path;
      if (text != null && text.isNotEmpty) {
        return make(HeapSpanKind.text, '$hexop · ${opcode.name}', 'String payload.', value: HeapTextValue(text));
      }
      final isContainer =
          opcode == HeapOpcode.container24 || opcode == HeapOpcode.container44 || opcode == HeapOpcode.container64;
      return make(
        isContainer ? HeapSpanKind.container : HeapSpanKind.record,
        '$hexop · ${opcode == HeapOpcode.unknown ? 'record' : opcode.name}',
        opcode.isDecoded
            ? 'A decoded ${opcode.name} record.'
            : 'A framed record with a ${rec.payload.length}-byte payload.',
      );
    }
  }
  final attr = decodeHeapAttr(body, offset);
  if (attr != null) {
    final attribute = attr.attribute;
    final name = attribute == HeapAttribute.unknown ? 'attribute 0x${attr.id.toRadixString(16)}' : attribute.attrName;
    final title = '${_hex2(lead)} · $name';
    switch (attr.kind) {
      case HeapAttrKind.color:
        return make(HeapSpanKind.color, title, 'Colour.', value: HeapColorValue(attr.isTransparent ? null : attr.rgb));
      case HeapAttrKind.controlParam:
        return make(
          HeapSpanKind.attribute,
          title,
          'Numeric-control parameter (f64).',
          value: HeapDoubleValue(attr.asDouble ?? 0),
        );
      case HeapAttrKind.stringBlob:
        return make(HeapSpanKind.text, title, 'String/blob.', value: HeapTextValue(attr.asString ?? ''));
      case HeapAttrKind.rectangle:
        final rect = attr.asRect;
        return make(
          HeapSpanKind.rectangle,
          title,
          'Rectangle (4× s16).',
          value: rect == null ? null : HeapRectValue(rect),
        );
      case HeapAttrKind.container:
        return make(
          HeapSpanKind.container,
          title,
          'A length-prefixed container whose lead byte counts its entries.',
          value: HeapNumberValue(attr.asInt ?? 0, attr.width),
        );
      default:
        return make(
          HeapSpanKind.attribute,
          title,
          '${attr.kind.name} attribute (${attr.width.name}).',
          value: HeapNumberValue(attr.asInt ?? 0, attr.width, ascii: attr.asciiText),
        );
    }
  }
  if (isTypeDescriptorToken(lead)) {
    return make(
      HeapSpanKind.typeToken,
      '04 ${_hex2(body[offset + 1])} · 04-token',
      'A bare 04 token; role not decoded.',
    );
  }
  return make(HeapSpanKind.other, 'lead 0x${lead.toRadixString(16)}', 'A framed record of no decoded family.');
}
