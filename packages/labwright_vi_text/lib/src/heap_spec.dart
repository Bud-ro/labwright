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
    HeapObjectNode() => _object(node),
    HeapGroupNode() => GroupSpec(
      node.open,
      close: node.closeLead == null ? null : (node.closeLead!, node.closeTag!),
      children: [for (final child in node.children) HeapSpec.of(child)],
    ),
    HeapRecordNode(:final bytes) => _typedRecord(bytes) ?? RawSpec(bytes),
  };

  static HeapSpec _object(HeapObjectNode node) {
    final object = ObjectSpec(
      HeapObjectClass.fromCode(node.kind),
      node.oid,
      kind: node.kind,
      lead: node.lead,
      tag: node.tag,
      wide: node.wide,
      close: node.closed ? (node.closeLead!, node.closeTag!) : null,
      children: [for (final child in node.children) HeapSpec.of(child)],
    );
    if (node.kind != HeapObjectClass.signal.code) return object;
    return WireSpec._of(object) ?? object;
  }

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

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _reproduces(HeapSpec spec, Uint8List bytes) {
    final out = BytesBuilder(copy: false);
    spec.encodeInto(out);
    return _sameBytes(out.takeBytes(), bytes);
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

/// One segment of a plain route: the way it runs and its length in pixels; the table carries
/// no length for a route's last segment.
final class WireLeg {
  const WireLeg(this.direction, [this.length]);

  const WireLeg.up([this.length]) : direction = WireRouteDirection.up;

  const WireLeg.left([this.length]) : direction = WireRouteDirection.left;

  const WireLeg.down([this.length]) : direction = WireRouteDirection.down;

  const WireLeg.right([this.length]) : direction = WireRouteDirection.right;

  final WireRouteDirection direction;

  final int? length;

  /// The plain table that runs [legs]: each leg turns across the one before it, and only the
  /// last has no length.
  static WireTable tableOf(List<WireLeg> legs) {
    if (legs.isEmpty) return const WireTable(1);
    final modes = <int>[legs.first.direction.code];
    for (var k = 1; k < legs.length; k++) {
      final d = legs[k].direction;
      if (d.isHorizontal == legs[k - 1].direction.isHorizontal) {
        throw ArgumentError.value(legs, 'legs', 'leg $k does not turn');
      }
      modes.add(d.dx + d.dy > 0 ? _turnPositive : _turnNegative);
    }
    final lengths = [for (final leg in legs.take(legs.length - 1)) leg.length];
    if (lengths.contains(null) || legs.last.length != null) {
      throw ArgumentError.value(
        legs,
        'legs',
        'only the last leg has no length',
      );
    }
    return WireTable(
      legs.length + 1,
      modes: modes,
      lengths: lengths.cast<int>(),
    );
  }

  /// The legs of a plain [table], or null for a table with a header or a mode that is not a
  /// turn.
  static List<WireLeg>? legsOf(WireTable table) {
    if (table.header != null) return null;
    final modes = table.modes;
    if (modes.isEmpty) return const [];
    var d = WireRouteDirection.fromCode(modes.first);
    if (d == null) return null;
    final legs = <WireLeg>[];
    for (var k = 0; k < modes.length; k++) {
      if (k > 0) {
        final positive = switch (modes[k]) {
          _turnPositive => true,
          _turnNegative => false,
          _ => null,
        };
        if (positive == null) return null;
        d = d!.isHorizontal
            ? (positive ? WireRouteDirection.down : WireRouteDirection.up)
            : (positive ? WireRouteDirection.right : WireRouteDirection.left);
      }
      legs.add(WireLeg(d!, k < table.lengths.length ? table.lengths[k] : null));
    }
    return legs;
  }

  static const int _turnPositive = 0;

  static const int _turnNegative = 1;
}

/// A `signal` object as a wire: the terminals it joins, its route, and its words, in the order
/// the file writes them; [HeapSpec.of] uses it only where it re-encodes the object exactly.
final class WireSpec extends HeapSpec {
  /// A wire over [endpoints] following [route], or [table] for a route that is not plain legs.
  WireSpec(
    this.oid,
    this.endpoints, {
    List<WireLeg>? route,
    WireTable? table,
    required this.state,
    required this.kind,
    this.flags,
  }) : table =
           table ??
           WireLeg.tableOf(
             route ?? (throw ArgumentError('a route or a table')),
           );

  final int oid;

  /// The terminals the signal joins; the route starts at the first.
  final List<int> endpoints;

  final WireTable table;

  /// The `signalState` word.
  final int state;

  /// The `lastSignalKind` word, a [ViSignalType].
  final int kind;

  /// The `objFlags` word, when the object carries one.
  final int? flags;

  /// [table] as legs, when it is plain.
  List<WireLeg>? get route => WireLeg.legsOf(table);

  static const int _u16ItemsTag = 0xfb;

  static bool _needsWide(int oid) => oid >= 0x8000;

  static Uint8List _termListOpen(int count) => Uint8List.fromList([
    0x11,
    HeapGroupTag.termList.tag,
    1,
    _u16ItemsTag,
    count >> 8,
    count & 0xff,
  ]);

  static final (int, int) _termListClose = (0x09, HeapGroupTag.termList.tag);

  /// The `signal` object the wire is written as.
  ObjectSpec get object => ObjectSpec(
    HeapObjectClass.signal,
    oid,
    children: [
      if (flags case final flags?)
        AttrSpec(HeapAttribute.objFlags.raw, flags, width: _widthOf(flags)),
      GroupSpec(
        _termListOpen(endpoints.length),
        close: _termListClose,
        children: [
          for (final e in endpoints) RefSpec(HeapRefKind.childRef.raw, e),
        ],
      ),
      AttrSpec(HeapAttribute.signalState.raw, state, width: _widthOf(state)),
      WireTableSpec.of(table),
      AttrSpec(
        HeapAttribute.lastSignalKind.raw,
        kind,
        width: HeapAttrWidth.u16,
      ),
    ],
  );

  @override
  void encodeInto(BytesBuilder out) => object.encodeInto(out);

  static HeapAttrWidth _widthOf(int value) => value < 0x100
      ? HeapAttrWidth.u8
      : value < 0x10000
      ? HeapAttrWidth.u16
      : value < 0x1000000
      ? HeapAttrWidth.u24
      : HeapAttrWidth.rgb;

  /// [object] as a wire when [object] is exactly what [WireSpec.object] builds from the
  /// fields read.
  static WireSpec? _of(ObjectSpec object) {
    if (object.lead != 0x10 ||
        object.tag != 0x19 ||
        object.close != (0x08, 0x19) ||
        object.wide != _needsWide(object.oid)) {
      return null;
    }
    var children = object.children;
    int? flags;
    if (children.firstOrNull case AttrSpec(
      attribute: HeapAttribute.objFlags,
      :final value,
      :final width,
    )) {
      if (width != _widthOf(value)) return null;
      flags = value;
      children = children.sublist(1);
    }
    if (children case [
      GroupSpec(:final open, :final close, children: final terms),
      AttrSpec(
        attribute: HeapAttribute.signalState,
        value: final state,
        width: final stateWidth,
      ),
      WireTableSpec(:final table),
      AttrSpec(
        attribute: HeapAttribute.lastSignalKind,
        value: final kind,
        width: HeapAttrWidth.u16,
      ),
    ]) {
      if (stateWidth != _widthOf(state)) return null;
      final endpoints = <int>[];
      for (final term in terms) {
        if (term is! RefSpec ||
            term.kind != HeapRefKind.childRef ||
            term.wide != _needsWide(term.oid)) {
          return null;
        }
        endpoints.add(term.oid);
      }
      if (close != _termListClose ||
          !HeapSpec._sameBytes(open, _termListOpen(endpoints.length))) {
        return null;
      }
      return WireSpec(
        object.oid,
        endpoints,
        table: table,
        state: state,
        kind: kind,
        flags: flags,
      );
    }
    return null;
  }
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
