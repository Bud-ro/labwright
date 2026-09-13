/// `DFDS` — the default data space: the saved value of every data-space type whose `TM80`
/// entry stores one, flattened back to back in map order with no header.
///
/// Which entries store a value is decided by their flag word ([TypeMapFlag]): entries with
/// [TypeMapFlag.hasSaveData] or [TypeMapFlag.storedValue0] store the whole value, entries with
/// [TypeMapFlag.unstored3], [TypeMapFlag.unstored10] or [TypeMapFlag.unstored11] store nothing,
/// and a cluster entry with [TypeMapFlag.frontPanelOperation], [TypeMapFlag.chartHistory],
/// [TypeMapFlag.member3Stored] or [TypeMapFlag.member2Stored] stores only the members that
/// flag names.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       rest  slots                      entry[]  one flattened value per type-map entry that
///                                                   stores one, in map order
///   +0    rest  value                      bytes    the entry's value flattened by its type, see
///                                                   below
/// ```
///
/// A value is flattened by its type, big-endian:
///
/// ```text
/// type                        flattened value
/// numeric, enum, boolean      the value, ViNumericType.width (or the enum's, unit's or
///                             boolean's width) bytes
/// string, picture, tag        [u32 length][bytes]
/// path                        [4cc PTH0/PTH1/PTH2][u32 length][bytes]
/// C string, Pascal string     u32
/// array                       [u32 size per dimension][elements]; an array data pointer is a u32
/// cluster                     the members in order
/// typedef                     the base's value
/// variant                     [u32 version] then, from LabVIEW 8.6, [u2p2 topLevelIndex] and the
///                             value of that top-level type (1-based; 0 is an empty variant),
///                             before 8.6 [u32 typeCount][descriptors][u2p2 hasValue][u2p2 index]
///                             [value]; then [u32 attributeCount] and per attribute
///                             [u32 nameLength][name][variant]
/// measure data                by ViMeasureDataFlavor: a waveform is [u8[16] t0][f64 dt]
///                             [u32 count][samples][error cluster][variant], an error cluster
///                             being [u8 status][i32 code][u32 length][source]; a timestamp is
///                             u8[16]; a digital table is [u32 count][u32 transitions]
///                             [u32 rows][u32 columns][u8 data]; a digital waveform replaces the
///                             samples with a digital table; dynamic data is [u32 count] f64
///                             waveforms
/// refnum                      u32, or as ViRefnumKind says for the resource, tag and class kinds
/// fixed point                 8 bytes
/// pointer                     nothing from LabVIEW 8.6, u32 before; a pointer-to is a u32
/// block, aligned block        the size word of the descriptor in bytes
/// repeated block              the client's value, count times
/// void, void block, marker    nothing
/// ```
///
/// The section usually stores the payload in the zlib envelope that [inflateHeapPayload]
/// opens, and sometimes plain; the layout is the inflated body.
///
/// [ViDataSpace] is a view over the payload recording where each slot starts; a
/// [DataSpaceSlot] names one; [DfdsContext] supplies the types, the map and the saving
/// version; [decodeDataSpace] requires the slots to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';
import '../decode.dart' show inflateHeapPayload;
import '../viparse.dart' show ViSection;
import 'TM80_type_map.dart';
import 'VCTP_type_pool.dart';
import 'vers_version.dart';

const _value = BlockField(0, null, 'value', 'bytes', 'the entry\'s value flattened by its type, see below');
const _slots = BlockField(
  0,
  null,
  'slots',
  'entry[]',
  'one flattened value per type-map entry that stores one, in map order',
  entry: [_value],
);

const BlockLayout dfdsLayout = [_slots];

/// The types, the type map and the saving version a data space is laid out by.
final class DfdsContext {
  /// The word-list map form: entries index the top-level list of [pool].
  DfdsContext.indexed(ViTypePool pool, ViTypeMapIndexed map, this.version)
    : _pool = pool,
      typeMap = map,
      types = pool.types;

  /// The inline map form of saves before the type pool: entries index the map's own
  /// descriptors.
  DfdsContext.inline(ViTypeMapInline map, this.version) : _pool = null, typeMap = map, types = map.types;

  final ViTypePool? _pool;

  final ViTypeMap typeMap;

  /// The descriptors that entry, member and element indices refer to.
  final List<ViType> types;

  final ViVersionWord version;

  int get entryCount => typeMap.count;

  int flagsAt(int entry) => typeMap.flagsAt(entry);

  /// For the indexed form, the position of [entry]'s type in the pool's top-level list; for
  /// the inline form, its descriptor index.
  int topLevelIndexAt(int entry) => switch (typeMap) {
    ViTypeMapIndexed(:final indexShift) => indexShift + entry - 1,
    final ViTypeMapInline map => map.typeIndexAt(entry),
  };

  /// The index in [types] of [entry]'s type.
  int typeIndexAt(int entry) => switch (typeMap) {
    ViTypeMapIndexed() => _pool!.topLevelIndexAt(topLevelIndexAt(entry)),
    ViTypeMapInline() => topLevelIndexAt(entry),
  };

  /// The type a variant names by its 1-based top-level index.
  ViType topLevelType(int oneBased) {
    final index = _pool!.topLevelIndexAt(oneBased - 1);
    assert(index < types.length, 'top-level type $oneBased is in the pool');
    return types[index];
  }

  int get _topLevelCount => switch (typeMap) {
    ViTypeMapIndexed() => _pool!.topLevelCount,
    ViTypeMapInline() => types.length,
  };
}

/// The context of every `DFDS` section of a VI, keyed by section index: the `TM80` with the
/// same index (or the only one), the `VCTP` for the indexed map form, and the `vers` version
/// word. A VI without a type map, a version word, or a type pool for an indexed map has none.
Map<int, DfdsContext> dataSpaceContexts(Iterable<ViSection> sections) {
  final version = versionWordFromSections(sections);
  if (version == null) return const {};
  ViTypePool? pool;
  final maps = <int, ViTypeMap>{};
  final dataSpaces = <int>[];
  for (final section in sections) {
    switch (section.tag) {
      case 'VCTP':
        pool ??= decodeTypePool(inflateHeapPayload(section.bytes) ?? section.bytes);
      case 'TM80':
        maps[section.index] = decodeTypeMap(inflateHeapPayload(section.bytes) ?? section.bytes);
      case 'DFDS':
        dataSpaces.add(section.index);
    }
  }
  if (maps.isEmpty) return const {};
  return {
    for (final index in dataSpaces)
      if (switch (maps[index] ?? maps.values.first) {
            final ViTypeMapInline map => DfdsContext.inline(map, version),
            final ViTypeMapIndexed map => pool == null ? null : DfdsContext.indexed(pool, map, version),
          }
          case final context?)
        index: context,
  };
}

/// One stored value: the whole value of the type-map entry [entryIndex].
final class DataSpaceSlot {
  const DataSpaceSlot({
    required this.entryIndex,
    required this.topLevelIndex,
    required this.offset,
    required this.length,
  });

  final int entryIndex;

  /// See [DfdsContext.topLevelIndexAt].
  final int topLevelIndex;

  final int offset;

  final int length;
}

/// A view over a `DFDS` payload.
class ViDataSpace implements BlockRecord {
  ViDataSpace._(this.bytes, this._slotOffsets, this._slotEntries, this._slotTopLevels);

  final Uint8List bytes;

  /// Where each whole-value slot starts, then where the last one ends.
  final List<int> _slotOffsets;

  final List<int> _slotEntries;

  final List<int> _slotTopLevels;

  int get slotCount => _slotEntries.length;

  DataSpaceSlot slotAt(int index) => DataSpaceSlot(
    entryIndex: _slotEntries[index],
    topLevelIndex: _slotTopLevels[index],
    offset: _slotOffsets[index],
    length: _slotOffsets[index + 1] - _slotOffsets[index],
  );

  List<DataSpaceSlot> get slots => [for (var i = 0; i < slotCount; i++) slotAt(i)];

  Uint8List slotBytes(int index) => Uint8List.sublistView(bytes, _slotOffsets[index], _slotOffsets[index + 1]);

  @override
  Uint8List serialize() => bytes;
}

ViDataSpace decodeDataSpace(Uint8List bytes, DfdsContext context) {
  final walk = _Walk(bytes, context);
  final entries = <int>[];
  final topLevels = <int>[];
  final offsets = <int>[];
  var at = 0;
  for (var entry = 0; entry < context.entryCount; entry++) {
    final flags = context.flagsAt(entry);
    if (TypeMapFlag.unstored3.isSetIn(flags) ||
        TypeMapFlag.unstored10.isSetIn(flags) ||
        TypeMapFlag.unstored11.isSetIn(flags)) {
      continue;
    }
    final topLevel = context.topLevelIndexAt(entry);
    assert(topLevel >= 0 && topLevel < context._topLevelCount, 'entry $entry names a top-level type');
    final typeIndex = context.typeIndexAt(entry);
    assert(typeIndex < context.types.length, 'entry $entry names a type in the pool');
    final type = context.types[typeIndex];
    if (TypeMapFlag.hasSaveData.isSetIn(flags) || TypeMapFlag.storedValue0.isSetIn(flags)) {
      entries.add(entry);
      topLevels.add(topLevel);
      offsets.add(at);
      at = walk.valueEnd(context.types, type, at, 0);
    } else if (type is ViClusterType && _specialMembers(flags, context.version).isNotEmpty) {
      var skip = TypeMapFlag.firstMemberSkipped.isSetIn(flags);
      for (final member in _specialMembers(flags, context.version)) {
        if (member >= type.memberCount) continue;
        if (skip) {
          skip = false;
          continue;
        }
        at = walk.valueEnd(context.types, context.types[type.memberIndexAt(member)], at, 0);
      }
    }
  }
  assert(at == bytes.length, 'the stored values tile the payload');
  offsets.add(at);
  return ViDataSpace._(bytes, offsets, entries, topLevels);
}

/// The cluster members a special flag stores, in order.
List<int> _specialMembers(int flags, ViVersionWord version) {
  if (TypeMapFlag.frontPanelOperation.isSetIn(flags)) return version.isAtLeast(10, 0) ? const [1] : const [2];
  if (TypeMapFlag.chartHistory.isSetIn(flags)) return const [1, 2, 3];
  if (TypeMapFlag.member3Stored.isSetIn(flags)) return const [3];
  if (TypeMapFlag.member2Stored.isSetIn(flags)) return const [2];
  return const [];
}

/// The flattened size of a fixed-point value.
const _fixedPointBytes = 8;

final class _Walk {
  _Walk(this.bytes, this.context) : view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData view;

  final DfdsContext context;

  /// Where the value of [type] flattened at [at] ends; member and element indices resolve in
  /// [types].
  int valueEnd(List<ViType> types, ViType type, int at, int depth) {
    assert(depth <= 2 * types.length + 2, 'types nest without cycles');
    assert(at <= bytes.length, 'a value starts inside the payload');
    switch (type) {
      case ViVoidType():
        return at;
      case ViNumericType():
        return _fixed(at, type.width);
      case ViEnumType():
        return _fixed(at, type.width);
      case ViUnitType():
        return _fixed(at, type.width);
      case ViBooleanType():
        return _fixed(at, type.width);
      case ViStringType():
        return switch (type.code) {
          TypeCode.cString || TypeCode.pascalString => _fixed(at, 4),
          TypeCode.path => _pathEnd(at),
          _ => _countedEnd(at),
        };
      case ViTagType():
        return _countedEnd(at);
      case ViArrayType():
        if (type.code == TypeCode.arrayDataPointer) return _fixed(at, 4);
        assert(type.code == TypeCode.array, 'a subarray stores no value');
        assert(type.elementIndex < types.length, 'the array element is a type');
        final element = types[type.elementIndex];
        var count = 1;
        for (var dim = 0; dim < type.dimCount; dim++) {
          count *= _u32(at) & 0x7fffffff;
          at += 4;
        }
        assert(count <= bytes.length - at, 'the element count fits the payload');
        for (var i = 0; i < count; i++) {
          at = valueEnd(types, element, at, depth + 1);
        }
        return at;
      case ViClusterType():
        for (var m = 0; m < type.memberCount; m++) {
          assert(type.memberIndexAt(m) < types.length, 'cluster member $m is a type');
          at = valueEnd(types, types[type.memberIndexAt(m)], at, depth + 1);
        }
        return at;
      case ViVariantType():
        return _variantEnd(at, depth + 1);
      case ViMeasureDataType():
        return _measureDataEnd(type, at, depth + 1);
      case ViRefnumType():
        return _refnumEnd(type, at);
      case ViPointerType():
        if (type.code == TypeCode.ptrTo) return _fixed(at, 4);
        return context.version.isAtLeast(8, 6) ? at : _fixed(at, 4);
      case ViTypedefType():
        return valueEnd(types, type.base, at, depth + 1);
      case ViUnknownType():
        return _blockEnd(types, type, at, depth);
      case ViFunctionType() || ViPolyViType():
        assert(false, 'a ${type.kind.name} stores no value');
        return at;
    }
  }

  int _fixed(int at, int width) {
    assert(at + width <= bytes.length, 'a $width-byte value fits the payload');
    return at + width;
  }

  int _u32(int at) {
    assert(at + 4 <= bytes.length, 'a length word fits the payload');
    return view.getUint32(at);
  }

  ({int value, int width}) _u2p2(int at) {
    assert(at + 2 <= bytes.length, 'a word fits the payload');
    final head = view.getUint16(at);
    if (head & 0x8000 == 0) return (value: head, width: 2);
    return (value: _u32(at) & 0x7fffffff, width: 4);
  }

  /// `[u32 length][bytes]`.
  int _countedEnd(int at) => _fixed(at + 4, _u32(at));

  int _pathEnd(int at) {
    assert(at + 8 <= bytes.length, 'a path has its tag and length');
    assert(
      bytes[at] == 0x50 &&
          bytes[at + 1] == 0x54 &&
          bytes[at + 2] == 0x48 &&
          bytes[at + 3] >= 0x30 &&
          bytes[at + 3] <= 0x32,
      'a path starts PTH0, PTH1 or PTH2',
    );
    return _fixed(at + 8, _u32(at + 4));
  }

  int _variantEnd(int at, int depth) {
    assert(at + 4 <= bytes.length, 'a variant has a version word');
    final version = decodeVersionWordAt(bytes, at);
    assert(version.isAtLeast(8, 0), 'a variant saved by LabVIEW 8 or later carries its version');
    at += 4;
    if (version.isAtLeast(8, 6)) {
      final topLevel = _u2p2(at);
      at += topLevel.width;
      if (topLevel.value != 0) {
        assert(topLevel.value <= context._topLevelCount, 'the variant names a top-level type');
        at = valueEnd(context.types, context.topLevelType(topLevel.value), at, depth + 1);
      }
    } else {
      final typeCount = _u32(at);
      at += 4;
      final offsets = descriptorOffsets(bytes, at, typeCount);
      final types = [
        for (final offset in offsets) ViType.at(bytes, offset, view.getUint16(offset), legacy: true),
      ];
      at = types.isEmpty ? at : types.last.end;
      final hasValue = _u2p2(at);
      at += hasValue.width;
      if (hasValue.value != 0) {
        final index = _u2p2(at);
        at += index.width;
        assert(index.value < types.length, 'the variant value is one of its descriptors');
        at = valueEnd(types, types[index.value], at, depth + 1);
      }
    }
    final attributeCount = _u32(at);
    at += 4;
    assert(attributeCount <= (bytes.length - at) ~/ 8, 'the attribute count fits the payload');
    for (var i = 0; i < attributeCount; i++) {
      at = _countedEnd(at);
      at = _variantEnd(at, depth + 1);
    }
    return at;
  }

  int _measureDataEnd(ViMeasureDataType type, int at, int depth) {
    final flavor = type.flavor;
    assert(flavor != null, 'measure data flavor ${type.flavorCode} has a known shape');
    switch (flavor!) {
      case ViMeasureDataFlavor.timeStamp:
        return _fixed(at, 16);
      case ViMeasureDataFlavor.digitalData:
        return _digitalTableEnd(at);
      case ViMeasureDataFlavor.digitalWaveform:
        at = _fixed(at, 24);
        at = _digitalTableEnd(at);
        at = _errorClusterEnd(at);
        return _variantEnd(at, depth);
      case ViMeasureDataFlavor.dynamicData:
        final count = _u32(at);
        at += 4;
        assert(count <= (bytes.length - at) ~/ 24, 'the waveform count fits the payload');
        for (var i = 0; i < count; i++) {
          at = _waveformEnd(at, ViMeasureDataFlavor.float64Waveform.sampleWidth!, depth);
        }
        return at;
      default:
        return _waveformEnd(at, flavor.sampleWidth!, depth);
    }
  }

  int _waveformEnd(int at, int sampleWidth, int depth) {
    at = _fixed(at, 24);
    final count = _u32(at);
    at = _fixed(at + 4, count * sampleWidth);
    at = _errorClusterEnd(at);
    return _variantEnd(at, depth);
  }

  int _digitalTableEnd(int at) {
    at = _fixed(at + 4, 4 * _u32(at));
    final rows = _u32(at);
    final columns = _u32(at + 4);
    return _fixed(at + 8, rows * columns);
  }

  int _errorClusterEnd(int at) => _countedEnd(_fixed(at, 5));

  int _refnumEnd(ViRefnumType type, int at) {
    switch (type.refnumKind) {
      case ViRefnumKind.imaq || ViRefnumKind.visa || ViRefnumKind.ivi || ViRefnumKind.userDefinedTag:
        return _countedEnd(at);
      case ViRefnumKind.userDefinedTagFlattened:
        at = _countedEnd(at);
        at = _countedEnd(at);
        at = _countedEnd(at);
        return _countedEnd(_fixed(at, 4));
      case ViRefnumKind.classInstance:
        final levels = _u32(at);
        at += 4;
        if (levels == 0) return at;
        assert(at < bytes.length, 'the library name has a length byte');
        at += (1 + bytes[at] + 3) & ~3;
        final singleZero = levels == 1 && _u32(at) == 0 && _u32(at + 4) == 0;
        at = _fixed(at, 8 * levels);
        if (singleZero) return at;
        for (var i = 0; i < levels; i++) {
          at = _countedEnd(at);
        }
        return at;
      default:
        return _fixed(at, 4);
    }
  }

  int _blockEnd(List<ViType> types, ViUnknownType type, int at, int depth) {
    final descriptor = ByteData.sublistView(type.bytes);
    switch (type.code) {
      case TypeCode.voidBlock || TypeCode.alignmentMarker:
        return at;
      case TypeCode.fixedPoint:
        return _fixed(at, _fixedPointBytes);
      case TypeCode.block || TypeCode.alignedBlock:
        return _fixed(at, descriptor.getUint32(type.offset + 4));
      case TypeCode.repeatedBlock:
        final count = descriptor.getUint32(type.offset + 4);
        final client = descriptor.getUint16(type.offset + 8);
        assert(client < types.length, 'the repeated block client is a type');
        for (var i = 0; i < count; i++) {
          at = valueEnd(types, types[client], at, depth + 1);
        }
        return at;
      default:
        assert(false, 'type 0x${type.code.toRadixString(16)} has a known flattened value');
        return at;
    }
  }
}
