part of 'seq_binary.dart';

enum _PropRecordField {
  lead(0),

  zeroA(2),

  kind(6),

  zeroB(10),

  typeNameIndex(14),

  nameIndex(18),

  value(22)
  ;

  const _PropRecordField(this.offset);

  final int offset;
}

const _propRecordLeads = {0x40, 0x44};
const _propTerminatorWidth = 2;

const _propMinKind = 2;
const _propMaxLeafKind = 14;

const _propScalarKind = 6;

/// Type names a property record may carry, with the width of the value that
/// follows the header when the record kind is scalar.
enum PropertyLeafType {
  /// One byte, 0 or 1.
  boolean('Bool', valueBytes: 1),

  /// A little-endian `f64`.
  number('Num', valueBytes: 8),

  /// A `u32` index into the string pool.
  string('Str', valueBytes: 4),

  /// A `u32` index into the string pool.
  path('Path', valueBytes: 4),

  /// A `u32` index into the string pool.
  expression('Expr', valueBytes: 4),

  object('Obj', valueBytes: 0),

  objects('Objs', valueBytes: 0)
  ;

  const PropertyLeafType(this.wire, {required this.valueBytes});

  final String wire;

  final int valueBytes;

  bool get valueIsPoolIndex => this == string || this == path || this == expression;

  static PropertyLeafType? of(String token) {
    for (final type in values) {
      if (type.wire == token) return type;
    }
    return null;
  }
}

class BinaryPropertyRecord {
  const BinaryPropertyRecord({
    required this.name,
    required this.leafType,
    required this.value,
    required this.offset,
    required this.length,
    this.lead = 0,
    this.flagsByte = 0,
    this.kind = 0,
  });

  final String name;

  final PropertyLeafType leafType;

  String get typeName => leafType.wire;

  final Object? value;

  final int offset;

  final int length;

  final int lead;

  /// TODO: bit meanings not decoded.
  final int flagsByte;

  final int kind;
}

List<String> _orderedStringPool(Uint8List body, int recordRegionLength) {
  final pool = <String>[];
  var offset = recordRegionLength;
  while (offset < body.length) {
    final start = offset;
    while (offset < body.length && body[offset] != 0) {
      offset++;
    }
    pool.add(String.fromCharCodes(body, start, offset));
    offset++;
  }
  return pool;
}

List<BinaryPropertyRecord> binaryPropertyRecords(Uint8List seqBytes) => _withLayout(seqBytes, _propertyRecordsFromBody);

List<BinaryPropertyRecord> _propertyRecordsFromBody(
  Uint8List body,
  int recordRegionLength, [
  List<String>? sharedPool,
]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);

  int wordAt(int offset) => view.getUint32(offset, Endian.little);
  final out = <BinaryPropertyRecord>[];

  var offset = 0;
  while (offset < recordRegionLength) {
    if (offset + _u32Bytes <= recordRegionLength && wordAt(offset) == _recordDelimiter) {
      offset += _u32Bytes;
      continue;
    }
    final headerEnd = offset + _PropRecordField.value.offset;
    if (_propRecordLeads.contains(body[offset + _PropRecordField.lead.offset]) && headerEnd <= recordRegionLength) {
      final kind = wordAt(offset + _PropRecordField.kind.offset);
      final typeIndex = wordAt(offset + _PropRecordField.typeNameIndex.offset);
      final nameIndex = wordAt(offset + _PropRecordField.nameIndex.offset);
      final leafType = typeIndex < pool.length ? PropertyLeafType.of(pool[typeIndex]) : null;
      final framed =
          wordAt(offset + _PropRecordField.zeroA.offset) == 0 &&
          wordAt(offset + _PropRecordField.zeroB.offset) == 0 &&
          kind >= _propMinKind &&
          kind <= _propMaxLeafKind &&
          nameIndex < pool.length &&
          leafType != null;
      if (framed) {
        var consumed = _PropRecordField.value.offset;
        Object? value;
        final valueAt = offset + _PropRecordField.value.offset;
        if (kind >= _propScalarKind && valueAt + leafType.valueBytes <= recordRegionLength) {
          switch (leafType) {
            case PropertyLeafType.string || PropertyLeafType.path || PropertyLeafType.expression:
              final poolIndex = wordAt(valueAt);
              if (poolIndex < pool.length) value = pool[poolIndex];
            case PropertyLeafType.boolean:
              value = body[valueAt] != 0;
            case PropertyLeafType.number:
              value = view.getFloat64(valueAt, Endian.little);
            case PropertyLeafType.object || PropertyLeafType.objects:
              break;
          }
          consumed += leafType.valueBytes;
        }
        if (offset + consumed + _propTerminatorWidth <= recordRegionLength &&
            body[offset + consumed] == 0 &&
            body[offset + consumed + 1] == 0) {
          consumed += _propTerminatorWidth;
        }
        out.add(
          BinaryPropertyRecord(
            name: pool[nameIndex],
            leafType: leafType,
            value: value,
            offset: offset,
            length: consumed,
            lead: body[offset + _PropRecordField.lead.offset],
            flagsByte: body[offset + _PropRecordField.lead.offset + 1],
            kind: kind,
          ),
        );
        offset += consumed;
        continue;
      }
    }
    offset++;
  }
  return out;
}

const _maxDeclarationPathWords = 8;

(List<String>, int)? _objectDeclarationPath(
  Uint8List body,
  ByteData view,
  List<String> pool,
  int offset,
  int recordRegionLength,
) {
  if (offset + _PropRecordField.zeroA.offset + _u32Bytes > recordRegionLength) return null;
  if (!_propRecordLeads.contains(body[offset + _PropRecordField.lead.offset])) return null;
  if (body[offset + 1] != 0) return null;
  final firstOffset = offset + _PropRecordField.zeroA.offset;
  final first = view.getUint32(firstOffset, Endian.little);
  if (first == 0 || first >= pool.length || pool[first].isEmpty) return null;

  final path = <String>[];
  var wordOffset = firstOffset;
  while (wordOffset + _u32Bytes <= recordRegionLength && path.length < _maxDeclarationPathWords) {
    final word = view.getUint32(wordOffset, Endian.little);
    if (word == 0) {
      wordOffset += _u32Bytes;
      continue;
    }
    if (word < pool.length && pool[word].isNotEmpty) {
      path.add(pool[word]);
      wordOffset += _u32Bytes;
    } else {
      break;
    }
  }
  return (path, wordOffset);
}

const _minDeclarationBytes = 8;

bool _isSequenceDeclaration(List<String> path) =>
    path.length >= 5 && path[0] == '[]' && path[2] == 'Objs' && path[3] == 'Seq' && path[4].startsWith('[');

List<String> binarySequenceNames(Uint8List seqBytes) => _withLayout(seqBytes, _sequenceNamesFromBody);

List<String> _sequenceNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final seen = <String>{};
  final names = <String>[];
  for (var offset = 0; offset + _minDeclarationBytes <= recordRegionLength; offset++) {
    final decl = _objectDeclarationPath(body, view, pool, offset, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    if (seen.add(decl.$1[1])) names.add(decl.$1[1]);
  }
  return names;
}
