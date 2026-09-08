part of 'seq_binary.dart';

const _typeStampMin = 0x386D4380;
const _typeStampMax = 0x83AA7E80;

final _typeNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.\- ]*$');

/// TODO: word 1 of the type-record head is not decoded.
const _typeStampOffset = 2 * _u32Bytes;

/// TODO: the extra word before a word-4 version triple is not decoded.
const _typeVersionTripleStarts = [3 * _u32Bytes, 4 * _u32Bytes];
const _typeVersionTripleWords = 3;

const _typeRecordMinBytes = (3 + _typeVersionTripleWords) * _u32Bytes;

List<String> binaryTypeNames(Uint8List seqBytes) => _withLayout(seqBytes, _typeNamesFromBody);

const _typeRecordPreambleBytes = 17;

const _typeIndexAnchorFields = {'DescriptionFormat', 'DefaultNameFormat'};

int deriveTypeIndexBase(ByteData view, List<String> pool, int recordRegionLength, List<BinaryTypeRecord> table) {
  final exprIdx = <int>[];
  for (var recordIndex = 0; recordIndex < table.length; recordIndex++) {
    if (table[recordIndex].name == 'Expression') exprIdx.add(recordIndex);
  }
  if (exprIdx.isEmpty) return 0;
  const framedValued = _fieldFramedBit | _fieldHasValueBit;
  Set<int>? common;
  var anchorSites = 0;
  for (var offset = 0; offset + 6 * _u32Bytes <= recordRegionLength; offset++) {
    final flags = view.getUint32(offset, Endian.little);
    if (flags & framedValued != framedValued || flags & ~_fieldKnownFlagBits != 0) continue;
    if (view.getUint32(offset + _u32Bytes, Endian.little) != 0) continue;
    if (view.getUint32(offset + 2 * _u32Bytes, Endian.little) != _recordDelimiter) continue;
    final nameWord = view.getUint32(offset + 4 * _u32Bytes, Endian.little);
    if (nameWord == 0 || nameWord >= pool.length || !_typeIndexAnchorFields.contains(pool[nameWord])) {
      continue;
    }
    final typeWord = view.getUint32(offset + 3 * _u32Bytes, Endian.little);
    if (typeWord < 1) continue;
    final cands = {for (final exprIndex in exprIdx) typeWord - 1 - exprIndex};
    common = common == null ? cands : common.intersection(cands);
    if (common.isEmpty) return 0;
    anchorSites++;
  }
  if (common == null) return 0;
  final base = common.reduce((left, right) => left.abs() < right.abs() ? left : right);
  if (base != 0 && anchorSites < 2) return 0;
  return base;
}

({List<BinarySequenceOutline> outlines, List<BinaryTypeRecord> typeRecords}) binaryOutlinesAndTypeRecordsFromBody(
  Uint8List body,
) {
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) {
    return const (outlines: [], typeRecords: []);
  }
  final pool = _orderedStringPool(body, recordRegionLength);
  final typeRecords = _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  return (
    outlines: _sequenceOutlinesFromBody(body, recordRegionLength, pool, [
      for (final record in typeRecords) record.name,
    ], typeRecords),
    typeRecords: typeRecords,
  );
}

List<String> _typeNamesFromBody(Uint8List body, int recordRegionLength, [List<String>? sharedPool]) => [
  for (final record in _typeRecordsFromBody(body, recordRegionLength, sharedPool: sharedPool, decodeBodies: false))
    record.name,
];

class BinaryTypeRecord {
  const BinaryTypeRecord({
    required this.name,
    required this.className,
    required this.typeCategory,
    required this.timestamp,
    required this.versions,
    required this.flags,
    this.fields,
    this.undecodedBody = false,
  });

  final String name;

  final String? className;

  SeqValueClass? get valueClass => SeqValueClass.of(className);

  final int typeCategory;

  final int timestamp;

  final List<String> versions;

  final List<int> flags;

  final List<BinaryTypeField>? fields;

  final bool undecodedBody;

  int? get typeFlags => flags.isNotEmpty ? flags[0] : null;
  int? get flagsForInstances => flags.length > 2 ? flags[1] : null;
  int? get instanceOverrideFlags =>
      flags.length == 4 ? flags[2] : (flags.length == 3 && typeCategory == 1 ? flags[2] : null);
  int? get valueFlags => switch (flags.length) {
    2 => flags[1],
    3 => typeCategory == 1 ? null : flags[2],
    4 => flags[3],
    _ => null,
  };

  Map<String, String> toAttributes() => {
    'typecategory': '$typeCategory',
    'timestamp': '$timestamp',
    if (versions.isNotEmpty) 'typeversion': versions[0],
    if (versions.length > 1) 'typelastmodversion': versions[1],
    if (versions.length > 2) 'typeminprodversion': versions[2],
    if (typeFlags != null) 'typeflags': '$typeFlags',
    if (flagsForInstances != null) 'flagsforinstances': '$flagsForInstances',
    if (instanceOverrideFlags != null) 'instanceoverrideflags': '$instanceOverrideFlags',
    if (valueFlags != null) 'valueflags': '$valueFlags',
  };
}

List<BinaryTypeRecord> binaryTypeRecords(Uint8List seqBytes) => _withLayout(seqBytes, _typeRecordsFromBody);

int binaryTypeIndexBase(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return 0;
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return 0;
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return 0;
  final table = _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool, decodeBodies: false);
  return deriveTypeIndexBase(ByteData.sublistView(body), pool, recordRegionLength, table);
}

const _fieldMaxAttrWords = 8;

const _typeMaxExtBlocks = 8;

const _maxFieldDepth = 64;

const _typeMaxFlagWords = 8;

List<BinaryTypeRecord> _typeRecordsFromBody(
  Uint8List body,
  int recordRegionLength, {
  List<String>? sharedPool,
  Map<String, int>? bodyOffsetsOut,
  Map<String, int>? headOffsetsOut,
  Map<String, int>? tripleOffsetsOut,
  bool decodeBodies = true,
}) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final versionLike = RegExp(r'^\d+\.\d+');
  final seen = <String>{};
  final records = <BinaryTypeRecord>[];
  final bodyOffsets = <int?>[];
  final headAts = <int>[];
  String? tok(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;
  for (var offset = 0; offset + _typeRecordMinBytes <= recordRegionLength; offset++) {
    final stamp = view.getUint32(offset + _typeStampOffset, Endian.little);
    if (stamp < _typeStampMin || stamp > _typeStampMax) continue;
    final nameIndex = view.getUint32(offset, Endian.little);
    if (nameIndex == 0 || nameIndex >= pool.length) continue;
    final name = pool[nameIndex];
    if (name.isEmpty || !_typeNamePattern.hasMatch(name)) continue;
    int? tripleAt;
    for (final tripleStart in _typeVersionTripleStarts) {
      if (offset + tripleStart + _typeVersionTripleWords * _u32Bytes > recordRegionLength) {
        continue;
      }
      var triple = true;
      for (var wordIndex = 0; wordIndex < _typeVersionTripleWords; wordIndex++) {
        final word = view.getUint32(offset + tripleStart + wordIndex * _u32Bytes, Endian.little);
        if (word == 0 || word >= pool.length || !versionLike.hasMatch(pool[word])) {
          triple = false;
          break;
        }
      }
      if (triple) {
        tripleAt = tripleStart;
        break;
      }
    }
    if (tripleAt == null) continue;
    if (!seen.add(name)) continue;
    final classWord = offset >= _u32Bytes ? view.getUint32(offset - _u32Bytes, Endian.little) : null;
    final className = classWord == null
        ? null
        : classWord == 0
        ? (pool[0].isNotEmpty && _TypeBodyParser._rootClassPattern.hasMatch(pool[0]) ? pool[0] : null)
        : tok(classWord);
    final typeCategory = view.getUint32(offset + _u32Bytes, Endian.little);
    final versions = [
      for (var wordIndex = 0; wordIndex < _typeVersionTripleWords; wordIndex++)
        pool[view.getUint32(offset + tripleAt + wordIndex * _u32Bytes, Endian.little)],
    ];
    final flags = <int>[];
    var flagAt = offset + tripleAt + _typeVersionTripleWords * _u32Bytes;
    var framed = false;
    while (flagAt + _u32Bytes <= recordRegionLength && flags.length < _typeMaxFlagWords) {
      final value = view.getUint32(flagAt, Endian.little);
      if (value == _recordDelimiter) {
        framed = true;
        break;
      }
      flags.add(value);
      flagAt += _u32Bytes;
    }
    int? bodyAt;
    if (framed) {
      while (flags.isNotEmpty && flags.last == 0) {
        flags.removeLast();
      }
      bodyAt = flagAt + _u32Bytes;
    } else {
      flags.clear();
      final tailAt = offset + tripleAt + _typeVersionTripleWords * _u32Bytes;
      if (tailAt + 2 * _u32Bytes <= recordRegionLength && view.getUint32(tailAt, Endian.little) == 1) {
        final idRef = view.getUint32(tailAt + _u32Bytes, Endian.little);
        if (idRef > 0 && idRef < pool.length && _looksLikeUniqueId(pool[idRef])) {
          bodyAt = tailAt + 2 * _u32Bytes;
        }
      }
    }
    records.add(
      BinaryTypeRecord(
        name: name,
        className: className,
        typeCategory: typeCategory,
        timestamp: stamp,
        versions: versions,
        flags: flags,
      ),
    );
    bodyOffsets.add(bodyAt);
    headAts.add(offset);
    if (bodyAt != null) bodyOffsetsOut?[name] = bodyAt;
    headOffsetsOut?[name] = offset;
    tripleOffsetsOut?[name] = tripleAt;
  }
  if (!decodeBodies) return records;
  final result = List.of(records);
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, result);
  for (var bodyOffsetsIndex = 0; bodyOffsetsIndex < result.length; bodyOffsetsIndex++) {
    final bodyAt = bodyOffsets[bodyOffsetsIndex];
    if (bodyAt == null) continue;
    final boundary = bodyOffsetsIndex + 1 < headAts.length
        ? headAts[bodyOffsetsIndex + 1] - _u32Bytes - _typeRecordPreambleBytes
        : null;
    final fields = _TypeBodyParser(view, pool, recordRegionLength, result, boundary, typeIndexBase).parse(bodyAt);
    result[bodyOffsetsIndex] = BinaryTypeRecord(
      name: records[bodyOffsetsIndex].name,
      className: records[bodyOffsetsIndex].className,
      typeCategory: records[bodyOffsetsIndex].typeCategory,
      timestamp: records[bodyOffsetsIndex].timestamp,
      versions: records[bodyOffsetsIndex].versions,
      flags: records[bodyOffsetsIndex].flags,
      fields: fields,
      undecodedBody: fields == null,
    );
  }
  return result;
}

List<({String name, int headAt, int bodyAt, int? end, int? bail})> binaryTypeBodyExtents(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return const [];
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final bodyOffsets = <String, int>{};
  final headOffsets = <String, int>{};
  final records = _typeRecordsFromBody(
    body,
    recordRegionLength,
    sharedPool: pool,
    bodyOffsetsOut: bodyOffsets,
    headOffsetsOut: headOffsets,
  );
  final extents = <({String name, int headAt, int bodyAt, int? end, int? bail})>[];
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, records);
  for (var recordIndex = 0; recordIndex < records.length; recordIndex++) {
    final record = records[recordIndex];
    final bodyAt = bodyOffsets[record.name];
    if (bodyAt == null) continue;
    final boundary = recordIndex + 1 < records.length
        ? (headOffsets[records[recordIndex + 1].name] ?? 0) - _u32Bytes - _typeRecordPreambleBytes
        : null;
    final parser = _TypeBodyParser(view, pool, recordRegionLength, records, boundary, typeIndexBase);
    final parsed = parser.parse(bodyAt) != null;
    extents.add((
      name: record.name,
      headAt: headOffsets[record.name] ?? -1,
      bodyAt: bodyAt,
      end: parsed ? parser.lastEndOffset : null,
      bail: parsed ? null : parser.lastFieldOffset ?? -1,
    ));
  }
  return extents;
}
