import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// One record of a heap, typed where its bytes are decided by its fields and verbatim where
/// they are not; [encodeInto] writes the record as the file holds it.
sealed class HeapSpec {
  const HeapSpec();

  void encodeInto(BytesBuilder out);

  /// The typed form of [node]: typed when re-encoding the decoded fields gives the node's own
  /// bytes, else verbatim.
  static HeapSpec of(HeapNode node) => switch (node) {
    HeapObjectNode() => ObjectSpec(
      HeapObjectClass.fromCode(node.kind),
      node.oid,
      kind: node.kind,
      lead: node.lead,
      tag: node.tag,
      wide: node.wide,
      close: node.closed ? (node.closeLead!, node.closeTag!) : null,
      children: [for (final child in node.children) HeapSpec.of(child)],
    ),
    HeapGroupNode() => GroupSpec(
      node.open,
      close: node.closeLead == null ? null : (node.closeLead!, node.closeTag!),
      children: [for (final child in node.children) HeapSpec.of(child)],
    ),
    HeapRecordNode(:final bytes) => _typedRecord(bytes) ?? RawSpec(bytes),
  };

  static HeapSpec? _typedRecord(Uint8List bytes) {
    final lead = bytes[0];
    if (bytes.length > 2 &&
        heapRawId(lead, bytes[1]) == HeapAttribute.compressedWireTable.raw) {
      final table = wireTableOfRecord(bytes);
      final decoded = table == null ? null : decodeWireTable(table);
      if (decoded != null) {
        final spec = WireTableSpec.of(decoded);
        if (_reproduces(spec, bytes)) return spec;
      }
    }
    if (lead == kHeapRecordPrefix) {
      final record = c4FrameAt(bytes, 0, '');
      if (record == null) return null;
      final spec = C4Spec(record.opcode, record.payload);
      return _reproduces(spec, bytes) ? spec : null;
    }
    if (decodeHeapRef(bytes, 0) case final ref?) {
      final spec = RefSpec(
        heapRawId(lead, bytes[1]),
        ref.targetOid,
        wide: ref.length == 10,
      );
      return _reproduces(spec, bytes) ? spec : null;
    }
    final attr = decodeHeapAttr(bytes, 0);
    if (attr == null || attr.length != bytes.length) return null;
    final spec = switch (attr.width) {
      HeapAttrWidth.u8 ||
      HeapAttrWidth.u16 ||
      HeapAttrWidth.u24 ||
      HeapAttrWidth.rgb => AttrSpec(
        attr.rawTag,
        attr.value as int,
        width: attr.width,
      ),
      HeapAttrWidth.flag => AttrSpec(
        attr.rawTag,
        attr.value as int,
        width: HeapAttrWidth.flag,
      ),
      _ => null,
    };
    return spec != null && _reproduces(spec, bytes) ? spec : null;
  }

  static bool _reproduces(HeapSpec spec, Uint8List bytes) {
    final out = BytesBuilder(copy: false);
    spec.encodeInto(out);
    final again = out.takeBytes();
    if (again.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (again[i] != bytes[i]) return false;
    }
    return true;
  }
}

/// An object: its class and id, the records inside it, and its close.
final class ObjectSpec extends HeapSpec {
  ObjectSpec(
    this.objectClass,
    this.oid, {
    int? kind,
    this.lead = 0x10,
    this.tag = 0x19,
    this.wide = false,
    this.close = (0x08, 0x19),
    this.children = const [],
  }) : kind = kind ?? objectClass.code;

  final HeapObjectClass objectClass;

  /// The class code, which [objectClass] names when it is catalogued.
  final int kind;

  final int oid;

  final int lead;

  final int tag;

  final bool wide;

  /// The close record's lead and tag; null for an object the file leaves open.
  final (int, int)? close;

  final List<HeapSpec> children;

  @override
  void encodeInto(BytesBuilder out) {
    out.add(encodeHeapObjectHeader(lead, tag, kind, oid, wide: wide));
    for (final child in children) {
      child.encodeInto(out);
    }
    if (close case (final lead, final tag)) out.add([lead, tag]);
  }
}

/// A group: its open record verbatim, the records inside it, and its close.
final class GroupSpec extends HeapSpec {
  const GroupSpec(
    this.open, {
    this.close = (0x08, 0x19),
    this.children = const [],
  });

  final Uint8List open;

  final (int, int)? close;

  final List<HeapSpec> children;

  @override
  void encodeInto(BytesBuilder out) {
    out.add(open);
    for (final child in children) {
      child.encodeInto(out);
    }
    if (close case (final lead, final tag)) out.add([lead, tag]);
  }
}

/// A scalar or flag attribute: its ten-bit id and its value in [width].
final class AttrSpec extends HeapSpec {
  const AttrSpec(this.rawId, this.value, {required this.width});

  final int rawId;

  final int value;

  final HeapAttrWidth width;

  HeapAttribute get attribute => HeapAttribute.fromRaw(rawId);

  @override
  void encodeInto(BytesBuilder out) {
    final bank = rawId >> 8;
    final id = rawId & 0xff;
    switch (width) {
      case HeapAttrWidth.flag:
        out.add([(value == 0 ? 0x00 : 0x10) | 4 | bank, id]);
      case HeapAttrWidth.u8:
        out.add([0x20 | 4 | bank, id, value & 0xff]);
      case HeapAttrWidth.u16:
        out.add([0x40 | 4 | bank, id, value >> 8 & 0xff, value & 0xff]);
      case HeapAttrWidth.u24:
        out.add([
          0x60 | 4 | bank,
          id,
          value >> 16 & 0xff,
          value >> 8 & 0xff,
          value & 0xff,
        ]);
      case HeapAttrWidth.rgb:
        out.add([
          0x80 | 4 | bank,
          id,
          value >> 24 & 0xff,
          value >> 16 & 0xff,
          value >> 8 & 0xff,
          value & 0xff,
        ]);
      case HeapAttrWidth.f64:
      case HeapAttrWidth.blob:
      case HeapAttrWidth.rect:
      case HeapAttrWidth.container:
        throw StateError('a ${width.name} attribute is not a scalar');
    }
  }
}

/// A reference to the object [oid], by the ten-bit id of the reference kind.
final class RefSpec extends HeapSpec {
  const RefSpec(this.rawId, this.oid, {this.wide = false});

  final int rawId;

  final int oid;

  final bool wide;

  HeapRefKind get kind => HeapRefKind.fromRaw(rawId);

  @override
  void encodeInto(BytesBuilder out) {
    final bytes = encodeHeapRef(0x14 | (rawId >> 8), rawId & 0xff, oid);
    if (wide && bytes.length == 6) {
      out.add([
        bytes[0],
        bytes[1],
        0x01,
        0xfd,
        0x80,
        0x00,
        oid >> 24 & 0xff,
        oid >> 16 & 0xff,
        oid >> 8 & 0xff,
        oid & 0xff,
      ]);
    } else {
      out.add(bytes);
    }
  }
}

/// A C4 record: its opcode and payload.
final class C4Spec extends HeapSpec {
  const C4Spec(this.opcode, this.payload);

  /// The bounds record, four `i16`s.
  factory C4Spec.bounds(int top, int left, int bottom, int right) =>
      C4Spec(HeapOpcode.bounds.byte, _rect(top, left, bottom, right));

  /// The caption record over [text]'s code units.
  factory C4Spec.caption(String text) =>
      C4Spec(HeapOpcode.caption.byte, Uint8List.fromList(text.codeUnits));

  final int opcode;

  final Uint8List payload;

  HeapOpcode get kind => HeapOpcode.fromByte(opcode);

  @override
  void encodeInto(BytesBuilder out) =>
      out.add(encodeHeapC4Record(opcode, payload));

  static Uint8List _rect(int top, int left, int bottom, int right) {
    final out = Uint8List(8);
    ByteData.sublistView(out)
      ..setInt16(0, top)
      ..setInt16(2, left)
      ..setInt16(4, bottom)
      ..setInt16(6, right);
    return out;
  }
}

/// A signal's `compressedWireTable` attribute: its route as [WireTable] words.
final class WireTableSpec extends HeapSpec {
  WireTableSpec(
    int pointCount, {
    List<int>? header,
    List<int> modes = const [],
    List<int> lengths = const [],
  }) : table = WireTable(
         pointCount,
         header: header,
         modes: modes,
         lengths: lengths,
       );

  const WireTableSpec.of(this.table);

  final WireTable table;

  @override
  void encodeInto(BytesBuilder out) =>
      out.add(encodeWireTableRecord(table.encode()));
}

/// A record kept verbatim.
final class RawSpec extends HeapSpec {
  const RawSpec(this.bytes);

  final Uint8List bytes;

  @override
  void encodeInto(BytesBuilder out) => out.add(bytes);
}

/// A heap body from [records]: the length word, then each record.
Uint8List encodeHeapSpecs(List<HeapSpec> records) {
  final out = BytesBuilder(copy: false)..add(const [0, 0, 0, 0]);
  for (final record in records) {
    record.encodeInto(out);
  }
  final bytes = out.takeBytes();
  ByteData.sublistView(bytes).setUint32(0, bytes.length - 4);
  return bytes;
}

/// The records of a heap [body], typed where their bytes are decided by their fields.
List<HeapSpec> heapSpecsOf(Uint8List body) => [
  for (final node in parseHeapTree(body)) HeapSpec.of(node),
];
