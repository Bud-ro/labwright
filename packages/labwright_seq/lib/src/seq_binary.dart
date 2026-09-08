import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

part 'seq_binary_metrics.dart';
part 'seq_binary_write.dart';

const _zlibCmf = 0x78;

enum ZlibFlag {
  none(0x01),

  byDefault(0x9c),

  best(0xda)
  ;

  const ZlibFlag(this.byte);
  final int byte;

  static bool isKnown(int flagByte) => flagByte == none.byte || flagByte == byDefault.byte || flagByte == best.byte;
}

const _minInflatedBytes = 64;

const _maxInflatedBytes = 128 * 1024 * 1024;

const _sentinelWord = 0xffffffff;

const _u32Bytes = 4;

const _f64Bytes = 8;

const _smallestNormalF64 = 2.2250738585072014e-308;

const _minRunLength = 3;

const _poolMinRunLength = 2;

const _recordDelimiter = 0xffffffff;

const _boundaryChainMin = 5;

const _minTableEntries = 5;

const _minSegmentChain = 2;

const _modelNameTokens = {
  'Sequence',
  'MainSequence',
  'SequenceFile',
  'Step',
  'StepType',
  'Locals',
  'Parameters',
};

const binaryNameScaffold = ['SequenceFileData', 'Data', 'Objs', 'Seq', '[0]'];

const _leadingWordCount = 3;

Uint8List? inflateBinaryBody(Uint8List bytes) {
  return _locateAndInflateBody(bytes)?.$2;
}

Uint8List? _inflateCapped(Uint8List input) {
  final sink = _CappedByteSink(_maxInflatedBytes);
  final decoderInput = ZLibDecoder().startChunkedConversion(sink);
  const chunk = 1 << 16;
  for (var chunkStart = 0; chunkStart < input.length && !sink.overflowed; chunkStart += chunk) {
    final end = chunkStart + chunk < input.length ? chunkStart + chunk : input.length;
    decoderInput.add(Uint8List.sublistView(input, chunkStart, end));
  }
  if (!sink.overflowed) decoderInput.close();
  return sink.overflowed ? null : sink.takeBytes();
}

class _CappedByteSink extends ByteConversionSink {
  _CappedByteSink(this._cap);

  final int _cap;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  bool overflowed = false;

  @override
  void add(List<int> chunk) {
    if (overflowed) return;
    _builder.add(chunk);
    if (_builder.length > _cap) overflowed = true;
  }

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    add(Uint8List.sublistView(chunk as Uint8List, start, end));
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

List<BinaryString> binaryBodyStrings(
  Uint8List seqBytes, {
  int minLength = _poolMinRunLength,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return binaryStrings(body, minLength: minLength);
}

class BinaryBodyLayout {
  const BinaryBodyLayout({
    required this.inflatedSize,
    required this.recordRegionLength,
    required this.stringCount,
    required this.sentinelCount,
    required this.segmentCount,
    required this.leadingWords,
  });

  final int inflatedSize;

  final int recordRegionLength;

  int get stringRegionOffset => recordRegionLength;

  final int stringCount;

  final int sentinelCount;

  final int segmentCount;

  // TODO: leadingWords[0] and the layout selector in leadingWords[1] are not decoded.
  final List<int> leadingWords;

  @override
  String toString() =>
      'BinaryBodyLayout(inflated=$inflatedSize, '
      'recordRegion=$recordRegionLength, strings=$stringCount, '
      'segments=$segmentCount, sentinels=$sentinelCount, lead=$leadingWords)';
}

BinaryBodyLayout? analyzeBinaryBody(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _layoutFromBody(body);
}

BinaryBodyLayout? _layoutFromBody(Uint8List body) =>
    _layoutFromRuns(body, binaryStrings(body, minLength: _minRunLength));

BinaryBodyLayout? _layoutFromRuns(Uint8List body, List<BinaryString> runs) {
  final boundary = _firstTableOffset(runs);
  if (boundary == null) return null;
  final stringCount = runs.where((run) => run.offset >= boundary).length;
  return BinaryBodyLayout(
    inflatedSize: body.length,
    recordRegionLength: boundary,
    stringCount: stringCount,
    sentinelCount: _countSentinels(body, boundary),
    segmentCount: _segmentsFrom(runs, boundary).length,
    leadingWords: _leadingWords(body, _leadingWordCount),
  );
}

typedef BinaryStringSegment = ({int offset, List<BinaryString> entries});

List<BinaryStringSegment> binaryStringSegments(
  Uint8List seqBytes, {
  int minChain = _minSegmentChain,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return _segmentsFromBody(body, minChain: minChain);
}

List<BinaryStringSegment> _segmentsFromBody(
  Uint8List body, {
  int minChain = _minSegmentChain,
}) => _segmentsFromRuns(binaryStrings(body, minLength: _minRunLength), minChain: minChain);

List<BinaryStringSegment> _segmentsFromRuns(
  List<BinaryString> runs, {
  int minChain = _minSegmentChain,
}) {
  final boundary = _firstTableOffset(runs);
  if (boundary == null) return const [];
  return [
    for (final chain in _segmentsFrom(runs, boundary, minChain: minChain)) (offset: chain.first.offset, entries: chain),
  ];
}

BinaryStringSegment? binaryNameTable(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _nameTableFromSegments(_segmentsFromBody(body));
}

List<String> binaryObjectNames(Uint8List seqBytes) {
  final table = binaryNameTable(seqBytes);
  if (table == null) return const [];
  return _objectNamesFrom([for (final entry in table.entries) entry.text]);
}

List<String> _objectNamesFrom(List<String> names) {
  var start = 0;
  while (start < names.length && start < binaryNameScaffold.length && names[start] == binaryNameScaffold[start]) {
    start++;
  }
  return names.sublist(start);
}

final _modulePathRe = RegExp(r'\.(vi|dll|seq|llb)$', caseSensitive: false);

bool isBinaryModulePath(String text) => text.contains('\\') && _modulePathRe.hasMatch(text);

List<String> binaryModulePaths(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryModulePath);

List<String> _poolWhere(Uint8List seqBytes, bool Function(String) keep) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return _poolWhereFrom(_segmentsFromBody(body), keep);
}

List<String> _poolWhereFrom(
  List<BinaryStringSegment> segments,
  bool Function(String) keep,
) {
  final seen = <String>{};
  final out = <String>[];
  for (final seg in segments) {
    for (final entry in seg.entries) {
      if (keep(entry.text) && seen.add(entry.text)) out.add(entry.text);
    }
  }
  return out;
}

List<String> binaryStepReferences(Uint8List seqBytes) => _poolWhere(seqBytes, _isStepRef);

bool _isStepRef(String text) => text.startsWith('ID#:');

final _exprRootRe = RegExp(r'\b(Locals|Parameters|Step|RunState|FileGlobals|StationGlobals|Seq|ThisContext)\.');

final _exprOpRe = RegExp(r'(==|!=|<=|>=|&&|\|\||\?.*:)');

final _exprFnRe = RegExp(r'\b(Abs|Str|Val|Round|Mid|Len|Left|Right|ResStr|LocalizeExpression|Mod)\s*\(');

bool isBinaryExpression(String text) {
  if (text.startsWith('ID#:') || isBinaryModulePath(text)) return false;
  return _exprRootRe.hasMatch(text) || _exprOpRe.hasMatch(text) || _exprFnRe.hasMatch(text);
}

List<String> binaryExpressions(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryExpression);

bool isBinaryQuotedLiteral(String text) =>
    text.length >= 2 && text.startsWith('"') && text.endsWith('"') && !isBinaryExpression(text);

List<String> binaryQuotedLiterals(Uint8List seqBytes) => _poolWhere(seqBytes, isBinaryQuotedLiteral);

BinaryStringSegment? _nameTableFromSegments(
  List<BinaryStringSegment> segments,
) {
  BinaryStringSegment? best;
  var bestHits = 0;
  for (final seg in segments) {
    final texts = {for (final entry in seg.entries) entry.text};
    final hits = _modelNameTokens.where(texts.contains).length;
    if (hits > bestHits) {
      bestHits = hits;
      best = seg;
    }
  }
  return best;
}

List<int> binaryRecordWords(Uint8List seqBytes) => _withLayout(seqBytes, _recordWordsFromBody);

List<T> _withLayout<T>(
  Uint8List seqBytes,
  List<T> Function(Uint8List body, int recordRegionLength) extract,
) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const <Never>[];
  final boundary = _recordRegionBoundary(body);
  if (boundary == null) return const <Never>[];
  return extract(body, boundary);
}

List<int> _recordWordsFromBody(Uint8List body, int recordRegionLength) {
  final view = ByteData.sublistView(body);
  final out = <int>[];
  for (var byteOffset = 0; byteOffset + _u32Bytes <= recordRegionLength; byteOffset += _u32Bytes) {
    out.add(view.getUint32(byteOffset, Endian.little));
  }
  return out;
}

const _minScalarMagnitude = 1e-9;

const _maxScalarMagnitude = 1e12;

List<double> binaryScalarDoubles(Uint8List seqBytes) => _withLayout(seqBytes, _scalarDoublesFromBody);

bool _isCleanScalar(double value) {
  if (!value.isFinite || value == 0) return false;
  final magnitude = value.abs();
  return magnitude >= _minScalarMagnitude && magnitude <= _maxScalarMagnitude;
}

List<double> _scalarDoublesFromBody(Uint8List body, int recordRegionLength) {
  final view = ByteData.sublistView(body);
  final seen = <double>{};
  final out = <double>[];
  for (var byteOffset = 0; byteOffset + _f64Bytes <= recordRegionLength; byteOffset += _u32Bytes) {
    if (view.getUint32(byteOffset, Endian.little) != 0) continue;
    final value = view.getFloat64(byteOffset, Endian.little);
    if (!_isCleanScalar(value)) continue;
    if (seen.add(value)) out.add(value);
  }
  return out;
}

class BinaryNamedScalar {
  const BinaryNamedScalar({
    required this.name,
    required this.rawTag,
    required this.rawTypeCode,
    required this.value,
    required this.wordIndex,
  });

  final String name;

  final int rawTag;

  final int rawTypeCode;

  final double value;

  final int wordIndex;
}

Map<int, String> _stringRegionNamesByRel(Uint8List body, int recordRegionLength) {
  final out = <int, String>{};
  for (final run in binaryStrings(body, minLength: _poolMinRunLength)) {
    if (run.offset >= recordRegionLength) out[run.offset - recordRegionLength] = run.text;
  }
  return out;
}

List<BinaryNamedScalar> binaryNamedScalarRecords(Uint8List seqBytes) => _withLayout(seqBytes, _namedScalarsFromBody);

List<BinaryNamedScalar> _namedScalarsFromBody(Uint8List body, int recordRegionLength) {
  final relToName = _stringRegionNamesByRel(body, recordRegionLength);
  if (relToName.isEmpty) return const [];

  final view = ByteData.sublistView(body);
  final out = <BinaryNamedScalar>[];
  final wordCount = recordRegionLength ~/ _u32Bytes;
  for (var wordIndex = 1; wordIndex + 3 < wordCount; wordIndex++) {
    final name = relToName[view.getUint32(wordIndex * _u32Bytes, Endian.little)];
    if (name == null) continue;
    final doubleOffset = (wordIndex + 2) * _u32Bytes;
    if (doubleOffset + _f64Bytes > recordRegionLength) continue;
    if (view.getUint32(doubleOffset, Endian.little) != 0) continue;
    final value = view.getFloat64(doubleOffset, Endian.little);
    if (!_isCleanScalar(value)) continue;
    out.add(
      BinaryNamedScalar(
        name: name,
        rawTag: view.getUint32((wordIndex - 1) * _u32Bytes, Endian.little),
        rawTypeCode: view.getUint32((wordIndex + 1) * _u32Bytes, Endian.little),
        value: value,
        wordIndex: wordIndex,
      ),
    );
  }
  return out;
}

class BinaryNamedRecord {
  const BinaryNamedRecord({
    required this.name,
    required this.count,
    required this.rawTag,
  });

  final String name;

  final int count;

  final int rawTag;
}

bool _isNameLike(String text) =>
    !isBinaryQuotedLiteral(text) && !isBinaryExpression(text) && !isBinaryModulePath(text) && !_isStepRef(text);

List<BinaryNamedRecord> binaryNamedRecords(Uint8List seqBytes) => _withLayout(seqBytes, _namedRecordsFromBody);

List<BinaryNamedRecord> _namedRecordsFromBody(Uint8List body, int recordRegionLength) {
  final relToName = _stringRegionNamesByRel(body, recordRegionLength);
  if (relToName.isEmpty) return const [];

  final view = ByteData.sublistView(body);
  final counts = <String, int>{};
  final tags = <String, Set<int>>{};
  final wordCount = recordRegionLength ~/ _u32Bytes;
  for (var wordIndex = 1; wordIndex + 1 < wordCount; wordIndex++) {
    final off = view.getUint32(wordIndex * _u32Bytes, Endian.little);
    if (off == 0) continue;
    final name = relToName[off];
    if (name == null || name.isEmpty || !_isNameLike(name)) continue;
    counts.update(name, (count) => count + 1, ifAbsent: () => 1);
    (tags[name] ??= <int>{}).add(view.getUint32((wordIndex - 1) * _u32Bytes, Endian.little));
  }

  final out = <BinaryNamedRecord>[];
  for (final entry in counts.entries) {
    final tagSet = tags[entry.key]!;
    if (entry.value < 2 || tagSet.length != 1) continue;
    out.add(
      BinaryNamedRecord(
        name: entry.key,
        count: entry.value,
        rawTag: tagSet.single,
      ),
    );
  }
  out.sort((left, right) => right.count.compareTo(left.count));
  return out;
}

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

const _fieldHasValueBit = 0x2;
const _fieldAttrBits = 0x4 | 0x8 | 0x20 | 0x40;
const _fieldFramedBit = 0x80;
const _fieldHasExtDataBit = 0x100;
const _fieldHasFormatBit = 0x200;

const _fieldHasNumericRepBit = 0x800;

const _fieldKnownFlagBits =
    _fieldHasValueBit |
    _fieldAttrBits |
    _fieldFramedBit |
    _fieldHasExtDataBit |
    _fieldHasFormatBit |
    _fieldHasNumericRepBit;

int _minAttrWords(int fieldFlags) => ((fieldFlags >> 3) & 1) + ((fieldFlags >> 5) & 1) + ((fieldFlags >> 6) & 1);

/// Field record wire forms; `DELIM` is [_recordDelimiter].
enum _FieldForm {
  /// `[name][value][attr words…][0]`
  compact,

  /// `[0][0][DELIM][name][childCount][children…]`
  descriptor,

  /// `[flags|0x80][0][DELIM][X][name][value…][attrs…][0]`
  framed,

  /// `[flags][0][DELIM][name][value?][attrs…][0]`
  framedLite,

  /// `[flags][0][cls][name][value-part][format?][extras…][0]`
  plain,
}

enum BinaryNumericRepresentation {
  int64(2, 'Int64'),

  uint64(3, 'UInt64')
  ;

  const BinaryNumericRepresentation(this.code, this.xmlName);

  final int code;

  final String xmlName;

  static BinaryNumericRepresentation? of(int code) => switch (code) {
    2 => int64,
    3 => uint64,
    _ => null,
  };

  static bool isInteger(int code) => of(code) != null;
}

const _typeMaxFields = 200;

const _maxArrayElements = 4096;

const _tailedValueClasses = {
  SeqValueClass.boolean,
  SeqValueClass.string,
  SeqValueClass.number,
  SeqValueClass.numbers,
  SeqValueClass.strings,
  SeqValueClass.objects,
  SeqValueClass.expression,
  SeqValueClass.path,
  SeqValueClass.reference,
};

const _unvaluedScalarClasses = {
  SeqValueClass.boolean,
  SeqValueClass.string,
  SeqValueClass.number,
  SeqValueClass.reference,
};

const _boundedArrayClasses = {SeqValueClass.numbers, SeqValueClass.strings, SeqValueClass.objects};

/// TODO: the 17-byte inter-record preamble is not decoded.
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

class _TypeBodyParser {
  _TypeBodyParser(this.view, this.pool, this.recordRegionLength, this.table, [this.bodyEndBoundary, int? typeIndexBase])
    : typeIndexBase = typeIndexBase ?? deriveTypeIndexBase(view, pool, recordRegionLength, table);

  final ByteData view;
  final List<String> pool;
  final int recordRegionLength;
  final List<BinaryTypeRecord> table;

  _DecodeSink ops = _DecodeSink.none;

  final int typeIndexBase;

  bool _validTypeWord(int typeWord) {
    final tableIndex = typeWord - 1 - typeIndexBase;
    return tableIndex >= 0 && tableIndex < table.length;
  }

  BinaryTypeRecord _tableRef(int typeWord) => table[typeWord - 1 - typeIndexBase];

  final int? bodyEndBoundary;

  int _u32(int offset) => view.getUint32(offset, Endian.little);
  String? _tok(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;

  static final _rootClassPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,39}$');

  String? _clsTok(int word) {
    if (word != 0) return _tok(word);
    if (pool.isEmpty) return null;
    final root = pool[0];
    return _rootClassPattern.hasMatch(root) ? root : null;
  }

  static final _boundPattern = RegExp(r'^(\[\d*\])+$');
  static bool _isBoundToken(String? token) => token != null && _boundPattern.hasMatch(token);

  bool _usedSpec = false;

  int _depth = 0;

  bool _inInstance = false;

  bool _partialStepArraysOk = false;

  bool _lastArrayPartial = false;

  Map<String, int>? _numericReprContext;

  static Map<String, int>? _reprsOf(BinaryTypeRecord ref) {
    Map<String, int>? out;
    for (final field in ref.fields ?? const <BinaryTypeField>[]) {
      final code = field.numericRepresentation;
      if (code != null && BinaryNumericRepresentation.isInteger(code)) {
        (out ??= {})[field.name] = code;
      }
    }
    return out;
  }

  int? _attrTail(int from, {int minWords = 0, List<int>? attrsOut}) {
    final rollbackMark = ops.mark();
    var offset = from;
    for (var attrIndex = 0; attrIndex <= _fieldMaxAttrWords; attrIndex++) {
      if (offset + _u32Bytes > recordRegionLength) return _blockBail(rollbackMark);
      final word = _u32(offset);
      if (word == 0 && attrIndex >= minWords) {
        ops.u32(offset, 0, _OpSource.grammar);
        return offset + _u32Bytes;
      }
      if (attrsOut != null) {
        attrsOut.add(word);
        ops.u32(offset, word, _OpSource.model);
      } else {
        ops.u32(offset, word, _OpSource.struct);
      }
      offset += _u32Bytes;
    }
    return _blockBail(rollbackMark);
  }

  /// TODO: only the extent is walked; spec contents are not decoded.
  int? _elementSpec(int offset) {
    final rollbackMark = ops.mark();
    final end = _elementSpecWalk(offset);
    ops.rollback(rollbackMark);
    return end;
  }

  int? _elementSpecWalk(int offset) {
    var cursor = offset;
    if (cursor >= recordRegionLength) return null;
    if (view.getUint8(cursor) == 0) cursor++;
    if (!_canRead(cursor) || _u32(cursor) != _recordDelimiter) return null;
    cursor += _u32Bytes;
    if (!_canRead(cursor)) return null;
    final typeWord = _u32(cursor);
    var typeWordOmitted = false;
    if (typeWord == _recordDelimiter) {
      typeWordOmitted = true;
      cursor += _u32Bytes;
    } else {
      if (!_validTypeWord(typeWord)) return null;
      cursor += _u32Bytes;
      if (!_canRead(cursor) || _u32(cursor) != _recordDelimiter) return null;
      cursor += _u32Bytes;
    }
    if (!_canRead(cursor)) return null;
    var tagged = false;
    if (_tok(_u32(cursor)) != null &&
        cursor + 2 * _u32Bytes <= recordRegionLength &&
        _u32(cursor + _u32Bytes) == 0x20000) {
      cursor += _u32Bytes;
    }
    if (_u32(cursor) == 0x20000) {
      tagged = true;
      cursor += _u32Bytes;
      if (!_canRead(cursor)) return null;
    }
    final count = _u32(cursor);
    if ((count < 1 && !tagged && typeWordOmitted) || count > _typeMaxFields) return null;
    cursor += _u32Bytes;
    final items = _fields(cursor, count);
    if (items == null) return null;
    return _attrTail(items.$2);
  }

  bool _canRead(int offset) => offset + _u32Bytes <= recordRegionLength;

  Null _blockBail(int rollbackMark) {
    ops.rollback(rollbackMark);
    return null;
  }

  static List<int>? _boundDims(String token) {
    final dims = <int>[];
    for (final match in RegExp(r'\[(\d*)\]').allMatches(token)) {
      final dim = int.tryParse(match.group(1)!);
      if (dim == null) return null;
      dims.add(dim);
    }
    return dims.isEmpty ? null : dims;
  }

  static int? _boundCount(String lbound, String ubound) {
    final lower = _boundDims(lbound);
    final upper = _boundDims(ubound);
    if (lower == null || upper == null || lower.length != upper.length) return null;
    var count = 1;
    for (var dimension = 0; dimension < lower.length; dimension++) {
      if (upper[dimension] < lower[dimension]) return null;
      count *= upper[dimension] - lower[dimension] + 1;
      if (count > _maxArrayElements) return null;
    }
    return count;
  }

  (List<BinaryTypeField>, int)? _stepElementPrefix(int offset, int count) {
    final elements = <BinaryTypeField>[];
    var cursor = offset;
    for (var elementIndex = 0; elementIndex < count; elementIndex++) {
      final rollbackMark = ops.mark();
      final element = _arrayElement(cursor);
      if (element == null || element.$1.valueClass != SeqValueClass.step) {
        ops.rollback(rollbackMark);
        break;
      }
      elements.add(element.$1);
      cursor = element.$2;
    }
    if (elements.isEmpty) return null;
    return (elements, cursor);
  }

  (List<BinaryTypeField>, int)? _populatedArrayTail(int offset, String lbound, String ubound, {List<int>? attrsOut}) {
    _lastArrayPartial = false;
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (_inInstance) {
      if (offset < recordRegionLength && view.getUint8(offset) == 0) {
        for (final start in _protoSpecEnds(offset + 1)) {
          final rollbackMark = ops.mark();
          final attrsMark = attrsOut?.length;
          ops.byte(offset, 0, _OpSource.grammar);
          ops.copy(offset + 1, start);
          final elements = _elementRun(start, count);
          if (elements == null) {
            ops.rollback(rollbackMark);
            continue;
          }
          final after = _attrTail(elements.$2, attrsOut: attrsOut);
          if (after != null) {
            _usedSpec = true;
            return (elements.$1, after);
          }
          ops.rollback(rollbackMark);
          if (attrsMark != null) attrsOut!.length = attrsMark;
        }
      }
    }
    final mDecl = ops.mark();
    final attrsDeclMark = attrsOut?.length;
    final tail = _attrTail(offset, attrsOut: attrsOut);
    if (tail == null || tail >= recordRegionLength || view.getUint8(tail) != 0) {
      ops.rollback(mDecl);
      if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
      return null;
    }
    ops.byte(tail, 0, _OpSource.grammar);
    for (final start in _protoSpecEnds(tail + 1)) {
      final rollbackMark = ops.mark();
      ops.copy(tail + 1, start);
      final elements = _elementRun(start, count);
      if (elements == null) {
        ops.rollback(rollbackMark);
        continue;
      }
      _usedSpec = true;
      return (elements.$1, elements.$2);
    }
    if (_partialStepArraysOk && !_inInstance) {
      for (final start in _protoSpecEnds(tail + 1)) {
        final rollbackMark = ops.mark();
        ops.copy(tail + 1, start);
        final prefix = _stepElementPrefix(start, count);
        if (prefix != null) {
          _usedSpec = true;
          _lastArrayPartial = true;
          return prefix;
        }
        ops.rollback(rollbackMark);
      }
    }
    ops.rollback(mDecl);
    if (attrsDeclMark != null) attrsOut!.length = attrsDeclMark;
    return null;
  }

  List<int> _protoSpecEnds(int offset) {
    final ends = <int>[];
    final six = _protoSpec(offset);
    if (six != null) ends.add(six);
    var cursor = offset;
    if (cursor < recordRegionLength && view.getUint8(cursor) == 0) cursor++;
    if (cursor + 5 * _u32Bytes <= recordRegionLength &&
        _u32(cursor) == _recordDelimiter &&
        _u32(cursor + _u32Bytes) == _recordDelimiter &&
        _tok(_u32(cursor + 2 * _u32Bytes)) != null &&
        _u32(cursor + 3 * _u32Bytes) == 0 &&
        _u32(cursor + 4 * _u32Bytes) == 0) {
      final five = cursor + 5 * _u32Bytes;
      if (!ends.contains(five)) ends.add(five);
    }
    ends.add(offset);
    return ends;
  }

  (List<BinaryTypeField>, int)? _scalarArrayTail(int offset, String lbound, String ubound, {List<int>? attrsOut}) {
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (offset + count * _f64Bytes > recordRegionLength) return null;
    final rollbackMark = ops.mark();
    final elements = <BinaryTypeField>[];
    var cursor = offset;
    for (var elementIndex = 0; elementIndex < count; elementIndex++, cursor += _f64Bytes) {
      final value = view.getFloat64(cursor, Endian.little);
      if (!value.isFinite || (value != 0 && value.abs() < _smallestNormalF64)) {
        return _blockBail(rollbackMark);
      }
      ops.f64(cursor, value);
      final text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
      elements.add(BinaryTypeField('', className: SeqValueClass.number.wire, value: text));
    }
    final attrsMark = attrsOut?.length;
    final after = _attrTail(cursor, attrsOut: attrsOut);
    if (after == null) {
      ops.rollback(rollbackMark);
      if (attrsMark != null) attrsOut!.length = attrsMark;
      return null;
    }
    return (elements, after);
  }

  (String, int)? _elemProtoTail(int offset) {
    if (offset + 3 * _u32Bytes > recordRegionLength) return null;
    final className = _tok(_u32(offset));
    if (className == null) return null;
    if (_u32(offset + _u32Bytes) != _recordDelimiter) return null;
    if (_u32(offset + 2 * _u32Bytes) != 0) return null;
    final rollbackMark = ops.mark();
    final after = _attrTail(offset + 3 * _u32Bytes);
    ops.rollback(rollbackMark);
    if (after == null) return null;
    return (className, after);
  }

  (List<BinaryTypeField>, int)? _elementRun(int offset, int count) {
    final rollbackMark = ops.mark();
    var cursor = offset;
    final elements = <BinaryTypeField>[];
    for (var elementIndex = 0; elementIndex < count; elementIndex++) {
      final element = _arrayElement(cursor);
      if (element == null) return _blockBail(rollbackMark);
      elements.add(element.$1);
      cursor = element.$2;
    }
    return (elements, cursor);
  }

  int? _protoSpec(int offset) {
    var cursor = offset;
    if (cursor >= recordRegionLength) return null;
    if (view.getUint8(cursor) == 0) cursor++;
    if (cursor + 6 * _u32Bytes > recordRegionLength) return null;
    if (_u32(cursor) != _recordDelimiter || _u32(cursor + _u32Bytes) != _recordDelimiter) {
      return null;
    }
    final value = _u32(cursor + 2 * _u32Bytes);
    if (value != 0 && _tok(value) == null) return null;
    if (_u32(cursor + 3 * _u32Bytes) != 0) return null;
    if (_u32(cursor + 5 * _u32Bytes) != 0) return null;
    if (value == 0 && _u32(cursor + 4 * _u32Bytes) == 0) return null;
    return cursor + 6 * _u32Bytes;
  }

  (BinaryTypeField, int)? _arrayElement(int offset) {
    for (final start in [offset, if (offset < recordRegionLength && view.getUint8(offset) == 0) offset + 1]) {
      if (!_canRead(start) || _u32(start) != _recordDelimiter) continue;
      final rollbackMark = ops.mark();
      if (start > offset) ops.byte(offset, 0, _OpSource.grammar);
      final block = _elementBlock(start);
      if (block == null) ops.rollback(rollbackMark);
      return block;
    }
    if (!_canRead(offset)) return null;
    if (_tok(_u32(offset)) == _stepToken) return _stepElement(offset);
    final outer = _inInstance;
    _inInstance = true;
    final field = _field(offset);
    _inInstance = outer;
    return field;
  }

  (BinaryTypeField, int)? _stepElement(int offset) {
    if (offset + 4 * _u32Bytes > recordRegionLength) return null;
    if (_tok(_u32(offset)) != 'Step') return null;
    final typeWord = _u32(offset + _u32Bytes);
    if (!_validTypeWord(typeWord)) return null;
    final name = _tok(_u32(offset + 2 * _u32Bytes));
    if (name == null) return null;
    final count = _u32(offset + 3 * _u32Bytes);
    if (count > _typeMaxFields) return null;
    final ref = _tableRef(typeWord);
    final rollbackMark = ops.mark();
    ops.poolRef(offset, _u32(offset));
    ops.u32(offset + _u32Bytes, typeWord, _OpSource.model);
    ops.poolRef(offset + 2 * _u32Bytes, _u32(offset + 2 * _u32Bytes));
    ops.u32(offset + 3 * _u32Bytes, count, _OpSource.model);
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = _reprsOf(ref);
    final children = _fields(offset + 4 * _u32Bytes, count);
    _inInstance = outerInstance;
    _numericReprContext = outerRepr;
    if (children == null) return _blockBail(rollbackMark);
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(rollbackMark);
    return (
      BinaryTypeField(
        name,
        className: SeqValueClass.step.wire,
        typeName: ref.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  (BinaryTypeField, int)? _elementBlock(int offset) {
    final rollbackMark = ops.mark();
    ops.u32(offset, _recordDelimiter, _OpSource.grammar);
    var cursor = offset + _u32Bytes;
    if (!_canRead(cursor)) return _blockBail(rollbackMark);
    final typeWord = _u32(cursor);
    cursor += _u32Bytes;
    if (!_canRead(cursor)) return _blockBail(rollbackMark);
    final word3 = _u32(cursor);
    var name = '';
    BinaryTypeRecord? ref;
    if (word3 == _recordDelimiter) {
      if (!_validTypeWord(typeWord)) return _blockBail(rollbackMark);
      ref = _tableRef(typeWord);
      ops.u32(offset + _u32Bytes, typeWord, _OpSource.model);
      ops.u32(cursor, _recordDelimiter, _OpSource.grammar);
      final word4At = cursor + _u32Bytes;
      if (ref.name == 'Expression' && _canRead(word4At) && _u32(word4At) > _typeMaxFields) {
        final value = _tok(_u32(word4At));
        if (value != null) {
          ops.poolRef(word4At, _u32(word4At));
          final attrs = <int>[];
          final after = _attrTail(word4At + _u32Bytes, attrsOut: attrs);
          if (after != null) {
            return (
              BinaryTypeField(
                '',
                className: SeqValueClass.expression.wire,
                typeName: 'Expression',
                value: value,
                attrWords: attrs,
              ),
              after,
            );
          }
        }
        return _blockBail(rollbackMark);
      }
    } else {
      final named = _tok(word3);
      if (named == null || typeWord == 0 || _tok(typeWord) == null) return _blockBail(rollbackMark);
      name = named;
      ops.poolRef(offset + _u32Bytes, typeWord);
      ops.poolRef(cursor, word3);
    }
    cursor += _u32Bytes;
    if (!_canRead(cursor)) return _blockBail(rollbackMark);
    final count = _u32(cursor);
    if (count > _typeMaxFields) return _blockBail(rollbackMark);
    ops.u32(cursor, count, _OpSource.model);
    cursor += _u32Bytes;
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = ref != null ? _reprsOf(ref) : null;
    final children = _fields(cursor, count);
    _inInstance = outerInstance;
    _numericReprContext = outerRepr;
    if (children == null) return _blockBail(rollbackMark);
    final attrs = <int>[];
    final after = _attrTail(children.$2, attrsOut: attrs);
    if (after == null) return _blockBail(rollbackMark);
    return (
      BinaryTypeField(
        name,
        className: ref != null ? (ref.className ?? SeqValueClass.object.wire) : null,
        typeName: ref?.name,
        children: children.$1,
        instanceOverrides: true,
        attrWords: attrs,
      ),
      after,
    );
  }

  /// TODO: only the extent is walked; block contents are not decoded.
  int? _extBlocksFrom(int offset, int remaining) {
    if (remaining == 0) return offset;
    if (offset + 10 > recordRegionLength) return null;
    if (_tok(_u32(offset)) == null) return null;
    final slotAt = offset + _u32Bytes + 2;
    if (slotAt + _u32Bytes <= recordRegionLength) {
      final slot = _u32(slotAt);
      if (slot == _recordDelimiter || _tok(slot) != null) {
        final rest = _extBlocksFrom(slotAt + _u32Bytes, remaining - 1);
        if (rest != null) return rest;
      }
    }
    final structEnd = offset + _u32Bytes + 2 + 20;
    if (structEnd > recordRegionLength) return null;
    return _extBlocksFrom(structEnd, remaining - 1);
  }

  int? _extTail(int from) {
    var cursor = from;
    for (var attrCount = 0; attrCount <= _fieldMaxAttrWords; attrCount++, cursor += _u32Bytes) {
      if (cursor + _u32Bytes > recordRegionLength) return null;
      final count = _u32(cursor);
      if (count == 0) return null;
      if (count <= _typeMaxExtBlocks) {
        final end = _extBlocksFrom(cursor + _u32Bytes, count);
        if (end != null && end + _u32Bytes <= recordRegionLength && _u32(end) == 0) {
          ops.blob(cursor, end);
          for (var wordOffset = from; wordOffset < cursor; wordOffset += _u32Bytes) {
            ops.u32(wordOffset, _u32(wordOffset), _OpSource.struct);
          }
          ops.u32(cursor, count, _OpSource.struct);
          ops.copy(cursor + _u32Bytes, end);
          ops.u32(end, 0, _OpSource.grammar);
          return end + _u32Bytes;
        }
      }
    }
    return null;
  }

  int? _refSpec(int offset) {
    var cursor = offset;
    if (cursor >= recordRegionLength) return null;
    if (view.getUint8(cursor) == 0) cursor++;
    if (cursor + 5 * _u32Bytes > recordRegionLength || _u32(cursor) != _recordDelimiter) {
      return null;
    }
    if (_u32(cursor + _u32Bytes) == 0) return null;
    for (var index = 2; index < 5; index++) {
      if (_u32(cursor + index * _u32Bytes) != 0) return null;
    }
    return cursor + 5 * _u32Bytes;
  }

  int? lastFieldOffset;

  int? lastEndOffset;

  List<(BinaryTypeField, int)> parseLeadingSubProps(int offset, int max, Set<String> groupNames) {
    _usedSpec = false;
    _depth = 0;
    final fields = <(BinaryTypeField, int)>[];
    var cur = offset;
    for (var index = 0; index < max; index++) {
      if (cur + 4 * _u32Bytes <= recordRegionLength) {
        final className = _tok(_u32(cur + 2 * _u32Bytes));
        final name = _tok(_u32(cur + 3 * _u32Bytes));
        if (className == 'Objs' && name != null && groupNames.contains(name)) {
          return fields;
        }
      }
      final field = _field(cur);
      if (field == null) return fields;
      cur = field.$2;
      fields.add((field.$1, cur));
    }
    return fields;
  }

  (BinaryTypeField, int)? parseFieldAt(int offset) {
    _usedSpec = false;
    _depth = 0;
    final parsed = _field(offset);
    if (parsed != null) lastEndOffset = parsed.$2;
    return parsed;
  }

  ({List<BinaryTypeField> fields, int? end}) parseStepTs(int offset) {
    const none = (fields: <BinaryTypeField>[], end: null);
    if (offset + 5 * _u32Bytes > recordRegionLength) return none;
    if (_u32(offset) != 0 || _u32(offset + _u32Bytes) != 0 || _u32(offset + 2 * _u32Bytes) != _recordDelimiter) {
      return none;
    }
    if (_tok(_u32(offset + 3 * _u32Bytes)) != 'TS') return none;
    final fullMark = ops.mark();
    if (parseFieldAt(offset) case (final full, final end) when full.name == 'TS' && full.children.isNotEmpty) {
      return (fields: full.children, end: end);
    }
    ops.rollback(fullMark);
    final idMark = ops.mark();
    if (parseFieldAt(offset + 5 * _u32Bytes) case (final idField, final end)
        when idField.valueClass == SeqValueClass.string &&
            idField.name == 'Id' &&
            (idField.value?.startsWith('ID#:') ?? false)) {
      ops.u32(offset, 0, _OpSource.grammar);
      ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
      ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
      ops.u32(offset + 4 * _u32Bytes, _u32(offset + 4 * _u32Bytes), _OpSource.model);
      return (fields: [idField], end: end);
    }
    ops.rollback(idMark);
    return none;
  }

  List<BinaryTypeField>? parse(int after) {
    lastFieldOffset = null;
    _usedSpec = false;
    if (after + 2 * _u32Bytes > recordRegionLength || _u32(after) != 0) {
      return null;
    }
    final rollbackMark = ops.mark();
    final count = _u32(after + _u32Bytes);
    (List<BinaryTypeField>, int)? parsed;
    if (count <= _typeMaxFields) {
      ops.u32(after, 0, _OpSource.grammar);
      ops.u32(after + _u32Bytes, count, _OpSource.model);
      parsed = _fields(after + 2 * _u32Bytes, count);
      if (parsed == null) ops.rollback(rollbackMark);
    }
    if (parsed == null && count >= 1 && count <= _typeMaxExtBlocks) {
      final extEnd = _extBlocksFrom(after + 2 * _u32Bytes, count);
      if (extEnd != null && extEnd + _u32Bytes <= recordRegionLength) {
        final subCount = _u32(extEnd);
        if (subCount <= _typeMaxFields) {
          ops.u32(after, 0, _OpSource.grammar);
          ops.u32(after + _u32Bytes, count, _OpSource.struct);
          ops.copy(after + 2 * _u32Bytes, extEnd);
          ops.u32(extEnd, subCount, _OpSource.model);
          parsed = _fields(extEnd + _u32Bytes, subCount);
          if (parsed == null) ops.rollback(rollbackMark);
          if (parsed != null) ops.blob(after + _u32Bytes, extEnd);
        }
      }
    }
    if (parsed == null) {
      final boundary = bodyEndBoundary;
      if (boundary == null) return null;
      ops.u32(after, 0, _OpSource.grammar);
      parsed = _fieldsUntil(after + _u32Bytes, boundary);
      if (parsed == null) return _blockBail(rollbackMark);
    }
    final boundary = bodyEndBoundary;
    if (_usedSpec && boundary != null && parsed.$2 > boundary) return _blockBail(rollbackMark);
    lastEndOffset = parsed.$2;
    return parsed.$1;
  }

  (List<BinaryTypeField>, int)? _fieldsUntil(int from, int boundary) {
    final rollbackMark = ops.mark();
    var offset = from;
    final fields = <BinaryTypeField>[];
    while (offset < boundary && fields.length <= _typeMaxFields) {
      final parsed = _fields(offset, 1);
      if (parsed == null) return _blockBail(rollbackMark);
      fields.addAll(parsed.$1);
      offset = parsed.$2;
    }
    if (offset != boundary) return _blockBail(rollbackMark);
    return (fields, offset);
  }

  T? _trial<T>(T? Function() body) {
    final rollbackMark = ops.mark();
    final parsed = body();
    if (parsed == null) ops.rollback(rollbackMark);
    return parsed;
  }

  (List<BinaryTypeField>, int)? _fields(int from, int count) {
    if (_depth >= _maxFieldDepth) return null;
    _depth++;
    try {
      return _trial(() => _fieldsInner(from, count));
    } finally {
      _depth--;
    }
  }

  (List<BinaryTypeField>, int)? _fieldsInner(int from, int count) {
    var offset = from;
    final fields = <BinaryTypeField>[];
    for (var elementIndex = 0; elementIndex < count; elementIndex++) {
      final field = _field(offset);
      if (field == null) return null;
      offset = field.$2;
      var specBytes = 0;
      if (field.$1.isArray && (field.$1.children.isEmpty || !_inInstance)) {
        while (true) {
          final specEnd = _elementSpec(offset) ?? _refSpec(offset) ?? _protoSpec(offset);
          if (specEnd == null) break;
          ops.copy(offset, specEnd);
          specBytes += specEnd - offset;
          offset = specEnd;
          _usedSpec = true;
        }
        if (specBytes == 0) {
          var lead = offset;
          if (lead < recordRegionLength && view.getUint8(lead) == 0) lead++;
          if (lead + _u32Bytes <= recordRegionLength && _u32(lead) == _recordDelimiter) {
            return null;
          }
        }
      }
      if (specBytes > 0) {
        ops.blob(field.$2, field.$2 + specBytes);
        fields.add(field.$1.withElementSpecBytes(specBytes));
      } else {
        fields.add(field.$1);
      }
    }
    return (fields, offset);
  }

  (BinaryTypeField, int)? _field(int offset) {
    lastFieldOffset = offset;
    return _trial(() => _fieldParse(offset));
  }

  (BinaryTypeField, int)? _fieldParse(int offset) {
    if (offset + 6 * _u32Bytes > recordRegionLength) return null;
    final fieldFlags = _u32(offset);
    return switch (_fieldFormAt(offset, fieldFlags)) {
      _FieldForm.compact => _parseCompactField(offset),
      _FieldForm.descriptor => _parseDescriptorField(offset),
      _FieldForm.framed => _parseFramedField(offset, fieldFlags),
      _FieldForm.framedLite => _parseFramedLiteField(offset, fieldFlags),
      _FieldForm.plain => _parsePlainField(offset, fieldFlags),
      null => null,
    };
  }

  _FieldForm? _fieldFormAt(int offset, int fieldFlags) {
    if (_u32(offset + _u32Bytes) != 0) return _FieldForm.compact;
    if (fieldFlags & ~_fieldKnownFlagBits != 0) return null;
    final delimited = _u32(offset + 2 * _u32Bytes) == _recordDelimiter;
    if (fieldFlags == 0 && delimited) return _FieldForm.descriptor;
    if (fieldFlags & _fieldFramedBit != 0) return _FieldForm.framed;
    return delimited ? _FieldForm.framedLite : _FieldForm.plain;
  }

  (BinaryTypeField, int)? _parseCompactField(int offset) {
    if (_inInstance) return null;
    final nameWord = _u32(offset);
    final valueWord = _u32(offset + _u32Bytes);
    final name = _tok(nameWord);
    final value = _tok(valueWord);
    if (name == null || value == null) return null;
    ops.poolRef(offset, nameWord);
    ops.poolRef(offset + _u32Bytes, valueWord);
    final attrs = <int>[];
    final after = _attrTail(offset + 2 * _u32Bytes, attrsOut: attrs);
    if (after == null) return null;
    return (BinaryTypeField(name, value: value, attrWords: attrs), after);
  }

  (BinaryTypeField, int)? _parseDescriptorField(int offset) {
    final name = _tok(_u32(offset + 3 * _u32Bytes));
    if (name == null) return null;
    final childCount = _u32(offset + 4 * _u32Bytes);
    if (childCount > _typeMaxFields) return null;
    ops.u32(offset, 0, _OpSource.grammar);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
    ops.u32(offset + 4 * _u32Bytes, childCount, _OpSource.model);
    final children = _fields(offset + 5 * _u32Bytes, childCount);
    if (children == null) return null;
    return (
      BinaryTypeField(
        name,
        className: SeqValueClass.object.wire,
        children: children.$1,
        instanceOverrides: true,
        fieldFlags: 0,
      ),
      children.$2,
    );
  }

  (BinaryTypeField, int)? _parseFramedField(int offset, int fieldFlags) {
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    if (hasNumericRep) return null;
    if (_u32(offset + 2 * _u32Bytes) != _recordDelimiter) return null;
    final typeWord = _u32(offset + 3 * _u32Bytes);
    final nameWord = _u32(offset + 4 * _u32Bytes);
    final name = nameWord == _recordDelimiter && _inInstance ? '' : _tok(nameWord);
    if (name == null) return null;
    ops.u32(offset, fieldFlags, _OpSource.model);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    if (nameWord == _recordDelimiter) {
      ops.u32(offset + 4 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    } else {
      ops.poolRef(offset + 4 * _u32Bytes, nameWord);
    }
    var next = offset + 5 * _u32Bytes;
    String? value;
    var typeName = 'Expression';
    var className = SeqValueClass.expression.wire;
    final boundPair =
        valued &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)));
    if (boundPair) {
      final lbound = _tok(_u32(next))!;
      final ubound = _tok(_u32(next + _u32Bytes))!;
      ops.u32(offset + 3 * _u32Bytes, typeWord, _OpSource.model);
      ops.poolRef(next, _u32(next));
      ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
      if (ubound == '[]') {
        if (lbound != '[0]') return null;
        final attrs = <int>[];
        final tail = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
        if (tail == null || tail >= recordRegionLength || view.getUint8(tail) != 0) {
          return null;
        }
        ops.byte(tail, 0, _OpSource.grammar);
        return (
          BinaryTypeField(
            name,
            className: SeqValueClass.objects.wire,
            arrayLBound: lbound,
            arrayUBound: ubound,
            intrinsicTypeId: typeWord == 0 ? null : typeWord,
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          tail + 1,
        );
      }
      final attrs = <int>[];
      final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
      if (elements == null) return null;
      return (
        BinaryTypeField(
          name,
          className: SeqValueClass.objects.wire,
          arrayLBound: lbound,
          arrayUBound: ubound,
          intrinsicTypeId: typeWord == 0 ? null : typeWord,
          children: elements.$1,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        elements.$2,
      );
    }
    if (typeWord == 0) {
      ops.u32(offset + 3 * _u32Bytes, 0, _OpSource.grammar);
      if (valued) {
        value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      } else {
        value = _inInstance ? null : '';
      }
    } else if (typeWord >= 1 && valued && _validTypeWord(typeWord) && _tableRef(typeWord).name == 'Expression') {
      value = _tok(_u32(next));
      if (value == null) return null;
      ops.u32(offset + 3 * _u32Bytes, typeWord, _OpSource.model);
      ops.poolRef(next, _u32(next));
      next += _u32Bytes;
    } else if (typeWord >= 2 && !valued && _validTypeWord(typeWord)) {
      final ref = _tableRef(typeWord);
      ops.u32(offset + 3 * _u32Bytes, typeWord, _OpSource.model);
      for (var attrCount = minAttrs; attrCount <= _fieldMaxAttrWords; attrCount++) {
        final countAt = next + attrCount * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final word = _u32(countAt);
        if (word == 0) break;
        if (word < 1 || word > _typeMaxFields) continue;
        final mInst = ops.mark();
        final instAttrs = <int>[];
        for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
          instAttrs.add(_u32(next + attrIndex * _u32Bytes));
          ops.u32(next + attrIndex * _u32Bytes, instAttrs[attrIndex], _OpSource.model);
        }
        ops.u32(countAt, word, _OpSource.model);
        final outerInstance = _inInstance;
        final outerRepr = _numericReprContext;
        _inInstance = true;
        _numericReprContext = _reprsOf(ref);
        final children = _fields(countAt + _u32Bytes, word);
        _inInstance = outerInstance;
        _numericReprContext = outerRepr;
        if (children != null) {
          return (
            BinaryTypeField(
              name,
              className: ref.className ?? SeqValueClass.object.wire,
              typeName: ref.name,
              children: children.$1,
              instanceOverrides: true,
              fieldFlags: fieldFlags,
              attrWords: instAttrs,
            ),
            children.$2,
          );
        }
        ops.rollback(mInst);
      }
      className = ref.className ?? SeqValueClass.object.wire;
      typeName = ref.name;
      value = _inInstance
          ? null
          : switch (SeqValueClass.from(className)) {
              SeqValueClass.string || SeqValueClass.path || SeqValueClass.expression => '',
              SeqValueClass.boolean => 'false',
              SeqValueClass.number => '0',
              _ => null,
            };
    } else if (typeWord == 1 && !valued) {
      ops.u32(offset + 3 * _u32Bytes, 1, _OpSource.grammar);
      final attrsFrom = next;
      next += minAttrs * _u32Bytes;
      if (next + _u32Bytes > recordRegionLength) return null;
      var overrideCount = _u32(next);
      for (var attrCount = 0; overrideCount > _typeMaxFields && attrCount < _fieldMaxAttrWords; attrCount++) {
        next += _u32Bytes;
        if (next + _u32Bytes > recordRegionLength) return null;
        overrideCount = _u32(next);
      }
      if (overrideCount > _typeMaxFields) return null;
      final customAttrs = <int>[];
      for (var wordOffset = attrsFrom; wordOffset < next; wordOffset += _u32Bytes) {
        customAttrs.add(_u32(wordOffset));
        ops.u32(wordOffset, customAttrs.last, _OpSource.model);
      }
      ops.u32(next, overrideCount, _OpSource.model);
      next += _u32Bytes;
      final outer = _inInstance;
      _inInstance = true;
      final overrides = _fields(next, overrideCount);
      _inInstance = outer;
      if (overrides == null) return null;
      return (
        BinaryTypeField(
          name,
          className: SeqValueClass.object.wire,
          children: overrides.$1,
          instanceOverrides: true,
          fieldFlags: fieldFlags,
          attrWords: customAttrs,
        ),
        overrides.$2,
      );
    } else {
      return null;
    }
    final attrs = <int>[];
    final after = _attrTail(next, minWords: minAttrs, attrsOut: attrs);
    if (after == null) return null;
    return (
      BinaryTypeField(
        name,
        className: className,
        typeName: typeName,
        value: value,
        fieldFlags: fieldFlags,
        attrWords: attrs,
      ),
      after,
    );
  }

  (BinaryTypeField, int)? _parseFramedLiteField(int offset, int fieldFlags) {
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    if (hasNumericRep) return null;
    final name = _tok(_u32(offset + 3 * _u32Bytes));
    if (name == null) return null;
    ops.u32(offset, fieldFlags, _OpSource.model);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(offset + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
    var next = offset + 4 * _u32Bytes;
    if (!valued) {
      for (var attrCount = minAttrs; attrCount <= _fieldMaxAttrWords; attrCount++) {
        final countAt = next + attrCount * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final word = _u32(countAt);
        if (word == 0) break;
        if (word < 1 || word > _typeMaxFields) continue;
        final mObj = ops.mark();
        final objAttrs = <int>[];
        for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
          objAttrs.add(_u32(next + attrIndex * _u32Bytes));
          ops.u32(next + attrIndex * _u32Bytes, objAttrs[attrIndex], _OpSource.model);
        }
        ops.u32(countAt, word, _OpSource.model);
        final outerInstance = _inInstance;
        _inInstance = true;
        final children = _fields(countAt + _u32Bytes, word);
        _inInstance = outerInstance;
        if (children != null) {
          return (
            BinaryTypeField(
              name,
              className: 'Obj',
              children: children.$1,
              instanceOverrides: true,
              fieldFlags: fieldFlags,
              attrWords: objAttrs,
            ),
            children.$2,
          );
        }
        ops.rollback(mObj);
      }
    }
    var value = _inInstance ? null : '';
    if (valued) {
      if (_u32(next) == _recordDelimiter) {
        ops.u32(next, _recordDelimiter, _OpSource.grammar);
        next += _u32Bytes;
      } else {
        final stored = _tok(_u32(next));
        if (stored == null) return null;
        value = stored;
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      }
    }
    final attrs = <int>[];
    final after = _attrTail(next, minWords: minAttrs, attrsOut: attrs);
    if (after == null) return null;
    return (BinaryTypeField(name, value: value, fieldFlags: fieldFlags, attrWords: attrs), after);
  }

  (BinaryTypeField, int)? _parsePlainField(int offset, int fieldFlags) {
    final hasExtData = fieldFlags & _fieldHasExtDataBit != 0;
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasFormat = fieldFlags & _fieldHasFormatBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    final className = _clsTok(_u32(offset + 2 * _u32Bytes));
    final name = _tok(_u32(offset + 3 * _u32Bytes));
    if (className == null || name == null) return null;
    final valueClass = SeqValueClass.from(className);
    ops.u32(offset, fieldFlags, _OpSource.model);
    ops.u32(offset + _u32Bytes, 0, _OpSource.grammar);
    ops.poolRef(offset + 2 * _u32Bytes, _u32(offset + 2 * _u32Bytes));
    ops.poolRef(offset + 3 * _u32Bytes, _u32(offset + 3 * _u32Bytes));
    var next = offset + 4 * _u32Bytes;
    if (!valued && !_tailedValueClasses.contains(valueClass)) {
      if (hasNumericRep) return null;
      for (var attrCount = 0; attrCount <= _fieldMaxAttrWords; attrCount++) {
        final countAt = next + attrCount * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final childCount = _u32(countAt);
        if (childCount > _typeMaxFields) continue;
        if (childCount == 0 && fieldFlags == 0x4 && countAt + 2 * _u32Bytes <= recordRegionLength) {
          final adjacent = _u32(countAt + _u32Bytes);
          if (adjacent >= 1 && adjacent <= _typeMaxFields) {
            final mAdj = ops.mark();
            final adjAttrs = <int>[];
            for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
              adjAttrs.add(_u32(next + attrIndex * _u32Bytes));
              ops.u32(next + attrIndex * _u32Bytes, adjAttrs[attrIndex], _OpSource.model);
            }
            adjAttrs.add(0);
            ops.u32(countAt, 0, _OpSource.model);
            ops.u32(countAt + _u32Bytes, adjacent, _OpSource.model);
            final children = _fields(countAt + 2 * _u32Bytes, adjacent);
            if (children != null) {
              return (
                BinaryTypeField(
                  name,
                  className: className,
                  children: children.$1,
                  fieldFlags: fieldFlags,
                  attrWords: adjAttrs,
                ),
                children.$2,
              );
            }
            ops.rollback(mAdj);
          }
        }
        final mDecl = ops.mark();
        final declAttrs = <int>[];
        for (var attrIndex = 0; attrIndex < attrCount; attrIndex++) {
          declAttrs.add(_u32(next + attrIndex * _u32Bytes));
          ops.u32(next + attrIndex * _u32Bytes, declAttrs[attrIndex], _OpSource.model);
        }
        ops.u32(countAt, childCount, _OpSource.model);
        final children = _fields(countAt + _u32Bytes, childCount);
        if (children == null) {
          ops.rollback(mDecl);
          continue;
        }
        return (
          BinaryTypeField(
            name,
            className: className,
            children: children.$1,
            fieldFlags: fieldFlags,
            attrWords: declAttrs,
          ),
          children.$2,
        );
      }
      return null;
    }
    if (!valued) {
      int? repr;
      if (hasNumericRep) {
        if (valueClass != SeqValueClass.number || !_canRead(next)) return null;
        repr = _u32(next);
        ops.u32(next, repr, _OpSource.model);
        next += _u32Bytes;
      }
      final attrs = <int>[];
      final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (!_unvaluedScalarClasses.contains(valueClass)) return null;
      return (
        BinaryTypeField(
          name,
          className: className,
          value: _inInstance || valueClass == SeqValueClass.reference
              ? null
              : switch (valueClass) {
                  SeqValueClass.boolean => 'false',
                  SeqValueClass.number => '0',
                  _ => '',
                },
          numericRepresentation: repr,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    if (_boundedArrayClasses.contains(valueClass) &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)))) {
      if (hasNumericRep) return null;
      final lbound = _tok(_u32(next))!;
      final ubound = _tok(_u32(next + _u32Bytes))!;
      ops.poolRef(next, _u32(next));
      ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
      if (valueClass == SeqValueClass.objects && ubound != '[]') {
        final attrs = <int>[];
        final elements = _populatedArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (elements != null) {
          return (
            BinaryTypeField(
              name,
              className: className,
              arrayLBound: lbound,
              arrayUBound: ubound,
              children: elements.$1,
              fieldFlags: fieldFlags,
              attrWords: attrs,
              partialArray: _lastArrayPartial,
            ),
            elements.$2,
          );
        }
      }
      if (valueClass == SeqValueClass.numbers && valued && ubound != '[]') {
        final attrs = <int>[];
        final run = _scalarArrayTail(next + 2 * _u32Bytes, lbound, ubound, attrsOut: attrs);
        if (run != null) {
          return (
            BinaryTypeField(
              name,
              className: className,
              arrayLBound: lbound,
              arrayUBound: ubound,
              children: run.$1,
              fieldFlags: fieldFlags,
              attrWords: attrs,
            ),
            run.$2,
          );
        }
      }
      final attrs = <int>[];
      var after = _attrTail(next + 2 * _u32Bytes, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (valueClass == SeqValueClass.objects) {
        if (after >= recordRegionLength || view.getUint8(after) != 0) {
          return null;
        }
        ops.byte(after, 0, _OpSource.grammar);
        after += 1;
        if (ubound == '[]') {
          final proto = _elemProtoTail(after);
          if (proto != null) {
            ops.blob(after, proto.$2);
            ops.copy(after, proto.$2);
            return (
              BinaryTypeField(
                name,
                className: className,
                arrayLBound: lbound,
                arrayUBound: ubound,
                elementSpecBytes: proto.$2 - after,
                fieldFlags: fieldFlags,
                attrWords: attrs,
              ),
              proto.$2,
            );
          }
        }
      }
      return (
        BinaryTypeField(
          name,
          className: className,
          arrayLBound: lbound,
          arrayUBound: ubound,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        after,
      );
    }
    switch (valueClass) {
      case SeqValueClass.string when !hasNumericRep:
        final value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        final attrs = <int>[];
        final after = hasExtData
            ? _extTail(next + _u32Bytes)
            : _attrTail(next + _u32Bytes, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(name, className: className, value: value, fieldFlags: fieldFlags, attrWords: attrs),
          after,
        );
      case SeqValueClass.boolean when !hasNumericRep:
        final value = view.getUint8(next);
        if (value > 1) return null;
        ops.byte(next, value, _OpSource.model);
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next + 1) : _attrTail(next + 1, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: className,
            value: value == 1 ? 'true' : 'false',
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
        );
      case SeqValueClass.number:
        int? repr;
        if (hasNumericRep) {
          if (!_canRead(next)) return null;
          repr = _u32(next);
          ops.u32(next, repr, _OpSource.model);
          next += _u32Bytes;
        }
        if (next + 2 * _u32Bytes > recordRegionLength) return null;
        var integer = repr != null
            ? BinaryNumericRepresentation.isInteger(repr)
            : _inInstance && _numericReprContext?[name] != null;
        if (!integer) {
          final raw = view.getFloat64(next, Endian.little);
          if (raw != 0 && raw.isFinite && raw.abs() < _smallestNormalF64) integer = true;
        }
        final String text;
        if (integer) {
          final value = view.getInt64(next, Endian.little);
          ops.i64(next, value);
          text = '$value';
        } else {
          final value = view.getFloat64(next, Endian.little);
          ops.f64(next, value);
          text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
        }
        next += 2 * _u32Bytes;
        if (hasFormat) {
          if (next + _u32Bytes > recordRegionLength || _tok(_u32(next)) == null) {
            return null;
          }
          ops.poolRef(next, _u32(next));
          next += _u32Bytes;
        }
        final attrs = <int>[];
        final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
        if (after == null) return null;
        return (
          BinaryTypeField(
            name,
            className: className,
            value: text,
            numericRepresentation: repr,
            fieldFlags: fieldFlags,
            attrWords: attrs,
          ),
          after,
        );
      default:
        return null;
    }
  }
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

class BinaryTypeField {
  const BinaryTypeField(
    this.name, {
    this.className,
    this.typeName,
    this.value,
    this.arrayLBound,
    this.arrayUBound,
    this.children = const [],
    this.instanceOverrides = false,
    this.elementSpecBytes,
    this.intrinsicTypeId,
    this.numericRepresentation,
    this.fieldFlags,
    this.attrWords = const [],
    this.partialArray = false,
  });

  final String name;

  final String? className;

  SeqValueClass? get valueClass => SeqValueClass.of(className);

  final String? typeName;

  final String? value;

  final String? arrayLBound;
  final String? arrayUBound;

  bool get isArray => arrayUBound != null;

  bool get isEmptyArray => arrayUBound == '[]';

  final List<BinaryTypeField> children;

  final int? elementSpecBytes;

  final bool instanceOverrides;

  /// TODO: the intrinsic-type id → name map is not decoded.
  final int? intrinsicTypeId;

  final int? numericRepresentation;

  bool get typeNameEngineIntrinsic => intrinsicTypeId != null || (instanceOverrides && typeName == null);

  bool get isPlainDeclaration => children.isNotEmpty && !instanceOverrides && typeName == null;

  final int? fieldFlags;

  final List<int> attrWords;

  final bool partialArray;

  BinaryTypeField withElementSpecBytes(int bytes) => BinaryTypeField(
    name,
    className: className,
    typeName: typeName,
    value: value,
    arrayLBound: arrayLBound,
    arrayUBound: arrayUBound,
    children: children,
    instanceOverrides: instanceOverrides,
    elementSpecBytes: bytes,
    intrinsicTypeId: intrinsicTypeId,
    numericRepresentation: numericRepresentation,
    fieldFlags: fieldFlags,
    attrWords: attrWords,
    partialArray: partialArray,
  );
}

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

const _stepToken = 'Step';
const _stepNameWordGap = 2;
const _stepContainerTokens = {'Objs', 'Data'};
const _stepExpressionKinds = {'Expression', 'ExprValue'};

bool _looksLikeUniqueId(String text) => text.length >= 15 && RegExp(r'[;\\<>^\]]').hasMatch(text);

List<String> binaryStepNames(Uint8List seqBytes) => _withLayout(seqBytes, _stepNamesFromBody);

List<String> _stepNamesFromBody(Uint8List body, int recordRegionLength) {
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final stepToken = pool.indexOf(_stepToken);
  if (stepToken < 0) return const [];
  final view = ByteData.sublistView(body);
  int wordAt(int offset) => view.getUint32(offset, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;

  final seen = <String>{};
  final names = <String>[];
  for (var offset = 0; offset + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; offset++) {
    if (wordAt(offset) != stepToken) continue;
    final kind = poolAt(wordAt(offset + _u32Bytes));
    final name = poolAt(wordAt(offset + _stepNameWordGap * _u32Bytes));
    final container = poolAt(wordAt(offset + (_stepNameWordGap + 1) * _u32Bytes));
    if (name == null || container == null || kind == null) continue;
    if (!_stepContainerTokens.contains(container)) continue;
    if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
    if (seen.add(name)) names.add(name);
  }
  return names;
}

final _stepGroupNames = {for (final group in StepGroup.values) group.key};

const _sequenceLeadingSubPropNames = {'Parameters', 'Locals'};

final _sequenceSubPropHead = ['Parameters', 'Locals', StepGroup.main.key, StepGroup.setup.key, StepGroup.cleanup.key];
const _sequenceSubPropTailNames = {'GotoCleanupOnFail', 'RecordResults', 'RTS', 'Requirements', 'FailureAction'};

final _sequenceSubPropClasses = {
  'Parameters': SeqValueClass.object,
  'Locals': SeqValueClass.object,
  StepGroup.main.key: SeqValueClass.objects,
  StepGroup.setup.key: SeqValueClass.objects,
  StepGroup.cleanup.key: SeqValueClass.objects,
  'RecordResults': SeqValueClass.boolean,
  'GotoCleanupOnFail': SeqValueClass.boolean,
  'RTS': SeqValueClass.object,
  'Requirements': SeqValueClass.object,
  'FailureAction': SeqValueClass.number,
};

const _sequenceRecordMaxSubProps = 12;

class _SequenceRecordWalk {
  const _SequenceRecordWalk(
    this.offset,
    this.name,
    this.comment,
    this.headWords,
    this.subpropCount,
    this.subProps,
    this.end,
  );
  final int offset;
  final String name;

  final int headWords;

  final String? comment;
  final int subpropCount;
  final List<(BinaryTypeField, int)> subProps;
  final int end;
}

List<_SequenceRecordWalk> _sequenceRecordWalks(
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  final seqIdx = <int>{
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (pool[poolIndex] == 'Sequence') poolIndex,
  };
  if (seqIdx.isEmpty) return const [];
  int u32(int offset) => view.getUint32(offset, Endian.little);
  String? poolAt(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)
    ..ops = sink
    .._partialStepArraysOk = true;

  (List<(BinaryTypeField, int)>, int) walkSubProps(int from, int count) {
    final subProps = <(BinaryTypeField, int)>[];
    final seenTail = <String>{};
    var cur = from;
    while (subProps.length < count) {
      final poolIndex = subProps.length;
      final mField = sink.mark();
      final parsed = parser.parseFieldAt(cur);
      if (parsed == null) break;
      final (field, fieldEnd) = parsed;
      var gated = false;
      if (poolIndex < _sequenceSubPropHead.length) {
        gated = field.name != _sequenceSubPropHead[poolIndex];
      } else {
        gated = !_sequenceSubPropTailNames.contains(field.name) || !seenTail.add(field.name);
      }
      if (!gated) gated = field.valueClass != _sequenceSubPropClasses[field.name];
      if (!gated &&
          _stepGroupNames.contains(field.name) &&
          field.children.any((child) => child.valueClass != SeqValueClass.step)) {
        gated = true;
      }
      if (gated) {
        sink.rollback(mField);
        break;
      }
      cur = fieldEnd;
      subProps.add((field, cur));
      if (_stepGroupNames.contains(field.name) &&
          ((!field.isEmptyArray && field.children.isEmpty) || field.partialArray)) {
        break;
      }
    }
    return (subProps, cur);
  }

  final walks = <_SequenceRecordWalk>[];
  var offset = 0;
  while (offset + 3 * _u32Bytes <= recordRegionLength) {
    if (!seqIdx.contains(u32(offset))) {
      offset++;
      continue;
    }
    final name = poolAt(u32(offset + _u32Bytes));
    if (name == null) {
      offset++;
      continue;
    }
    _SequenceRecordWalk? walked;
    for (final withComment in const [false, true]) {
      final countAt = offset + (withComment ? 3 : 2) * _u32Bytes;
      if (countAt + _u32Bytes > recordRegionLength) continue;
      final count = u32(countAt);
      if (count < 1 || count > _sequenceRecordMaxSubProps) continue;
      final mCand = sink.mark();
      final (subProps, end) = walkSubProps(countAt + _u32Bytes, count);
      if (subProps.isEmpty || subProps.first.$1.name != 'Parameters') {
        sink.rollback(mCand);
        continue;
      }
      final commentWord = withComment ? u32(offset + 2 * _u32Bytes) : 0;
      final comment = withComment && commentWord > _sequenceRecordMaxSubProps ? poolAt(commentWord) : null;
      sink.poolRef(offset, u32(offset));
      sink.poolRef(offset + _u32Bytes, u32(offset + _u32Bytes));
      if (withComment) {
        if (comment != null) {
          sink.poolRef(offset + 2 * _u32Bytes, commentWord);
        } else {
          sink.u32(offset + 2 * _u32Bytes, commentWord, _OpSource.struct);
        }
      }
      sink.u32(countAt, count, _OpSource.model);
      walked = _SequenceRecordWalk(offset, name, comment, withComment ? 4 : 3, count, subProps, end);
      break;
    }
    if (walked == null) {
      offset++;
      continue;
    }
    walks.add(walked);
    sink.claim(offset, offset + walked.headWords * _u32Bytes, _tierSemantic);
    var fieldStart = offset + walked.headWords * _u32Bytes;
    for (final (_, fieldEnd) in walked.subProps) {
      sink.claim(fieldStart, fieldEnd, _tierSemantic);
      fieldStart = fieldEnd;
    }
    offset = walked.end > offset ? walked.end : offset + 1;
  }
  return walks;
}

const _stepDataSubPropNames = {'Measurement', 'PinMapPath'};

class BinaryStepRef {
  const BinaryStepRef(
    this.name, {
    this.typeName,
    this.viPath,
    this.pythonModule,
    this.pythonFunction,
    this.tsSubProps = const [],
    this.dataSubProps = const [],
  });

  final String name;

  final String? typeName;

  final List<BinaryTypeField> tsSubProps;

  final List<BinaryTypeField> dataSubProps;

  final String? viPath;
  final String? pythonModule;
  final String? pythonFunction;

  @override
  String toString() => 'BinaryStepRef($name${typeName != null ? ': $typeName' : ''})';
}

class BinarySequenceOutline {
  const BinarySequenceOutline({
    required this.name,
    required this.setup,
    required this.main,
    required this.cleanup,
    this.ungrouped = const [],
    this.leadingSubProps = const [],
    this.tailSubProps = const [],
    this.comment,
    this.groupArrays = const [],
  });

  final String name;

  final List<BinaryStepRef> setup;
  final List<BinaryStepRef> main;
  final List<BinaryStepRef> cleanup;

  final List<BinaryStepRef> ungrouped;

  final List<BinaryTypeField> leadingSubProps;

  final List<BinaryTypeField> tailSubProps;

  final String? comment;

  final List<BinaryTypeField> groupArrays;
}

List<BinarySequenceOutline> binarySequenceOutlines(Uint8List seqBytes) =>
    _withLayout(seqBytes, _sequenceOutlinesFromBody);

List<BinarySequenceOutline> _sequenceOutlinesFromBody(
  Uint8List body,
  int recordRegionLength, [
  List<String>? sharedPool,
  List<String>? sharedTypeNames,
  List<BinaryTypeRecord>? sharedTypeRecords,
  _DecodeSink sink = _DecodeSink.none,
]) {
  final pool = sharedPool ?? _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return const [];
  final view = ByteData.sublistView(body);

  final table = sharedTypeRecords ?? _typeRecordsFromBody(body, recordRegionLength, sharedPool: pool);
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, table);
  final recordWalks = _sequenceRecordWalks(view, pool, recordRegionLength, table, typeIndexBase, sink);

  final sequenceDecls = <(int, String)>[];
  for (var offset = 0; offset + _minDeclarationBytes <= recordRegionLength; offset++) {
    final decl = _objectDeclarationPath(body, view, pool, offset, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    sequenceDecls.add((offset, decl.$1[1]));
    sink.claim(offset, decl.$2, _tierSemantic);
    sink.byte(offset, body[offset], _OpSource.struct);
    sink.byte(offset + 1, body[offset + 1], _OpSource.struct);
    for (
      var wordOffset = offset + _PropRecordField.zeroA.offset;
      wordOffset + _u32Bytes <= decl.$2;
      wordOffset += _u32Bytes
    ) {
      final word = view.getUint32(wordOffset, Endian.little);
      if (word == 0) {
        sink.u32(wordOffset, 0, _OpSource.grammar);
      } else {
        sink.poolRef(wordOffset, word);
      }
    }
  }
  if (sequenceDecls.isEmpty) {
    for (final walk in recordWalks) {
      sequenceDecls.add((walk.offset, walk.name));
    }
  }
  if (sequenceDecls.isEmpty) return const [];

  final markers = <(int, StepGroup)>[];
  for (final record in _propertyRecordsFromBody(body, recordRegionLength)) {
    final group = StepGroup.byKey(record.name);
    if (group != null && record.leafType == PropertyLeafType.objects) {
      markers.add((record.offset, group));
    }
  }

  final typeNames = sharedTypeNames ?? _typeNamesFromBody(body, recordRegionLength, pool);
  final stepToken = pool.indexOf(_stepToken);
  final found = <(int, String, int)>[];
  int wordAt(int offset) => view.getUint32(offset, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;
  if (stepToken > 0) {
    for (var offset = 0; offset + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; offset++) {
      if (wordAt(offset) != stepToken) continue;
      final typeWord = wordAt(offset + _u32Bytes);
      final kind = poolAt(typeWord);
      final name = poolAt(wordAt(offset + _stepNameWordGap * _u32Bytes));
      final container = poolAt(wordAt(offset + (_stepNameWordGap + 1) * _u32Bytes));
      if (name == null || container == null || kind == null) continue;
      if (!_stepContainerTokens.contains(container)) continue;
      if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
      found.add((offset, name, typeWord - 1));
    }
  }
  Set<int> indicesOf(String token) => {
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (pool[poolIndex] == token) poolIndex,
  };
  final viPathIdx = indicesOf('VIPath');
  final modulePathIdx = indicesOf('ModulePath');
  final functionIdx = indicesOf('FunctionOrAttributeName');
  String? pairIn(int start, int end, Set<int> nameIdx) {
    if (nameIdx.isEmpty) return null;
    for (var offset = start; offset + 2 * _u32Bytes <= end; offset++) {
      if (!nameIdx.contains(wordAt(offset))) continue;
      final value = poolAt(wordAt(offset + _u32Bytes));
      if (value != null) {
        sink.claim(offset, offset + 2 * _u32Bytes, _tierSemantic);
        sink.poolRef(offset, wordAt(offset));
        sink.poolRef(offset + _u32Bytes, wordAt(offset + _u32Bytes));
        return value;
      }
    }
    return null;
  }

  final tsParser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;

  final steps = <(int, BinaryStepRef)>[];
  for (var stepIndex = 0; stepIndex < found.length; stepIndex++) {
    final (offset, name, typeIndex) = found[stepIndex];
    final spanEnd = stepIndex + 1 < found.length ? found[stepIndex + 1].$1 : recordRegionLength;
    final (fields: tsSubProps, end: tsEnd) = tsParser.parseStepTs(offset + 4 * _u32Bytes);
    sink.claim(offset, offset + 4 * _u32Bytes, _tierSemantic);
    sink.poolRef(offset, wordAt(offset));
    final typeWord = wordAt(offset + _u32Bytes);
    if (typeIndex >= 0 && typeIndex < typeNames.length) {
      sink.u32(offset + _u32Bytes, typeWord, _OpSource.model);
    } else {
      sink.u32(offset + _u32Bytes, typeWord, _OpSource.struct);
    }
    sink.poolRef(offset + 2 * _u32Bytes, wordAt(offset + 2 * _u32Bytes));
    sink.poolRef(offset + 3 * _u32Bytes, wordAt(offset + 3 * _u32Bytes));
    if (tsSubProps.isNotEmpty && tsEnd != null) {
      sink.claim(offset + 4 * _u32Bytes, tsEnd, _tierSemantic);
    }
    final dataSubProps = <BinaryTypeField>[];
    if (tsSubProps.isNotEmpty && tsEnd != null) {
      var cur = tsEnd;
      while (cur < spanEnd) {
        final mData = sink.mark();
        final parsed = tsParser.parseFieldAt(cur);
        if (parsed == null) break;
        final (field, fieldEnd) = parsed;
        if (!_stepDataSubPropNames.contains(field.name) || fieldEnd > spanEnd) {
          sink.rollback(mData);
          break;
        }
        dataSubProps.add(field);
        sink.claim(cur, fieldEnd, _tierSemantic);
        cur = fieldEnd;
      }
    }
    steps.add((
      offset,
      BinaryStepRef(
        name,
        typeName: typeIndex >= 0 && typeIndex < typeNames.length ? typeNames[typeIndex] : null,
        viPath: pairIn(offset, spanEnd, viPathIdx),
        pythonModule: pairIn(offset, spanEnd, modulePathIdx),
        pythonFunction: pairIn(offset, spanEnd, functionIdx),
        tsSubProps: tsSubProps,
        dataSubProps: dataSubProps,
      ),
    ));
  }

  sequenceDecls.sort((left, right) => left.$1.compareTo(right.$1));
  final outlines = {
    for (final (_, name) in sequenceDecls) name: {for (final group in StepGroup.values) group: <BinaryStepRef>[]},
  };
  String sequenceAt(int offset) {
    var owner = sequenceDecls.first.$2;
    for (final (declOffset, name) in sequenceDecls) {
      if (declOffset < offset) owner = name;
    }
    return owner;
  }

  final ungrouped = <String, List<BinaryStepRef>>{
    for (final (_, name) in sequenceDecls) name: <BinaryStepRef>[],
  };
  for (final (stepOffset, step) in steps) {
    StepGroup? group;
    for (final (markerOffset, markerGroup) in markers) {
      if (markerOffset < stepOffset) group = markerGroup;
    }
    final owner = sequenceAt(stepOffset);
    if (group == null) {
      ungrouped[owner]!.add(step);
      continue;
    }
    outlines[owner]![group]!.add(step);
  }

  final leading = _sequenceLeadingSubProps(
    body,
    view,
    pool,
    recordRegionLength,
    table,
    typeIndexBase,
    {
      for (final (_, name) in sequenceDecls) name,
    },
    sink,
  );

  final tail = _sequenceTailSubProps(view, pool, recordRegionLength, table, typeIndexBase, sequenceDecls, sink);

  final groups = <String, List<BinaryTypeField>>{};
  final comments = <String, String>{};
  for (final walk in recordWalks) {
    if (groups.containsKey(walk.name) || comments.containsKey(walk.name)) continue;
    final walked = [
      for (final (field, _) in walk.subProps)
        if (_stepGroupNames.contains(field.name)) field,
    ];
    if (walked.isNotEmpty) groups[walk.name] = walked;
    if (walk.comment != null) comments[walk.name] = walk.comment!;
  }

  final seenNames = <String>{};
  return [
    for (final (_, name) in sequenceDecls)
      if (seenNames.add(name))
        BinarySequenceOutline(
          name: name,
          setup: outlines[name]![StepGroup.setup]!,
          main: outlines[name]![StepGroup.main]!,
          cleanup: outlines[name]![StepGroup.cleanup]!,
          ungrouped: ungrouped[name]!,
          leadingSubProps: leading[name] ?? const [],
          tailSubProps: tail[name] ?? const [],
          comment: comments[name],
          groupArrays: groups[name] ?? const [],
        ),
  ];
}

Map<String, List<BinaryTypeField>> _sequenceTailSubProps(
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase,
  List<(int, String)> sequenceDecls, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  if (sequenceDecls.isEmpty) return const {};
  int u32(int offset) => view.getUint32(offset, Endian.little);
  Set<int> indicesOf(String token) => {
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (pool[poolIndex] == token) poolIndex,
  };
  final anchors = [
    for (final spec in _tailSubProps) (indicesOf(spec.name), indicesOf(spec.className.wire), spec),
  ];
  final sorted = [...sequenceDecls]..sort((left, right) => left.$1.compareTo(right.$1));
  String ownerOf(int offset) {
    var owner = sorted.first.$2;
    for (final (declOffset, name) in sorted) {
      if (declOffset < offset) owner = name;
    }
    return owner;
  }

  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  final result = <String, List<BinaryTypeField>>{};
  final seenPerOwner = <String, Set<String>>{};
  for (var offset = 0; offset + 4 * _u32Bytes <= recordRegionLength; offset++) {
    for (final (nameIdx, classIdx, spec) in anchors) {
      if (u32(offset + _u32Bytes) != 0) continue;
      if (!classIdx.contains(u32(offset + 2 * _u32Bytes))) continue;
      if (!nameIdx.contains(u32(offset + 3 * _u32Bytes))) continue;
      final mAnchor = sink.mark();
      final parsed = parser.parseFieldAt(offset);
      if (parsed == null) continue;
      final (field, fieldEnd) = parsed;
      final owner = ownerOf(offset);
      final seen = seenPerOwner.putIfAbsent(owner, () => <String>{});
      if (!spec.accepts(field) || !seen.add(spec.name)) {
        sink.rollback(mAnchor);
        continue;
      }
      sink.claim(offset, fieldEnd, _tierSemantic);
      result.putIfAbsent(owner, () => <BinaryTypeField>[]).add(field);
    }
  }
  return result;
}

class _TailSubProp {
  const _TailSubProp(this.name, this.className, this.accepts);
  final String name;
  final SeqValueClass className;
  final bool Function(BinaryTypeField) accepts;
}

final _tailSubProps = <_TailSubProp>[
  _TailSubProp('RecordResults', SeqValueClass.boolean, (field) => field.name == 'RecordResults' && field.value != null),
  _TailSubProp('FailureAction', SeqValueClass.number, (field) => field.name == 'FailureAction' && field.value != null),
  _TailSubProp(
    'Requirements',
    SeqValueClass.object,
    (field) =>
        field.name == 'Requirements' &&
        field.valueClass == SeqValueClass.object &&
        field.children.any((child) => child.name == 'Links' && child.valueClass == SeqValueClass.strings),
  ),
  _TailSubProp(
    'RTS',
    SeqValueClass.object,
    (field) => field.name == 'RTS' && field.valueClass == SeqValueClass.object && field.children.isNotEmpty,
  ),
];

Map<String, List<BinaryTypeField>> _sequenceLeadingSubProps(
  Uint8List body,
  ByteData view,
  List<String> pool,
  int recordRegionLength,
  List<BinaryTypeRecord> table,
  int typeIndexBase,
  Set<String> sequenceNames, [
  _DecodeSink sink = _DecodeSink.none,
]) {
  final sequenceToken = pool.indexOf('Sequence');
  if (sequenceToken <= 0) return const {};
  final nameIndices = <int, String>{
    for (var poolIndex = 1; poolIndex < pool.length; poolIndex++)
      if (sequenceNames.contains(pool[poolIndex])) poolIndex: pool[poolIndex],
  };
  if (nameIndices.isEmpty) return const {};
  int u32(int offset) => view.getUint32(offset, Endian.little);
  final result = <String, List<BinaryTypeField>>{};
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  for (var offset = 0; offset + 3 * _u32Bytes <= recordRegionLength; offset += 1) {
    if (u32(offset) != sequenceToken) continue;
    final name = nameIndices[u32(offset + _u32Bytes)];
    if (name == null || result.containsKey(name)) continue;
    final count = u32(offset + 2 * _u32Bytes);
    if (count < 1 || count > _typeMaxFields) continue;
    final mWalk = sink.mark();
    final decoded = parser.parseLeadingSubProps(offset + 3 * _u32Bytes, count, _stepGroupNames);
    final subProps = <BinaryTypeField>[];
    var keptEnd = offset + 3 * _u32Bytes;
    for (final (field, fieldEnd) in decoded) {
      if (!_sequenceLeadingSubPropNames.contains(field.name)) break;
      subProps.add(field);
      keptEnd = fieldEnd;
    }
    if (subProps.isEmpty) {
      sink.rollback(mWalk);
      continue;
    }
    sink.rollbackTailFrom(mWalk, keptEnd);
    sink.poolRef(offset, u32(offset));
    sink.poolRef(offset + _u32Bytes, u32(offset + _u32Bytes));
    sink.u32(offset + 2 * _u32Bytes, count, _OpSource.model);
    sink.claim(offset, keptEnd, _tierSemantic);
    result[name] = subProps;
  }
  return result;
}

bool _packedAfter(BinaryString prev, BinaryString cur) => cur.offset == prev.offset + prev.text.length + 1;

List<List<BinaryString>> _segmentsFrom(
  List<BinaryString> runs,
  int from, {
  int minChain = _minSegmentChain,
}) {
  final segs = <List<BinaryString>>[];
  var chain = <BinaryString>[];
  for (final run in runs) {
    if (run.offset < from) continue;
    if (chain.isNotEmpty) {
      final prev = chain.last;
      if (!_packedAfter(prev, run)) {
        if (chain.length >= minChain) segs.add(chain);
        chain = <BinaryString>[];
      }
    }
    chain.add(run);
  }
  if (chain.length >= minChain) segs.add(chain);
  return segs;
}

List<int> _leadingWords(Uint8List body, int count) {
  final out = <int>[];
  final view = ByteData.sublistView(body);
  for (var elementIndex = 0; elementIndex + _u32Bytes <= body.length && out.length < count; elementIndex += _u32Bytes) {
    out.add(view.getUint32(elementIndex, Endian.little));
  }
  return out;
}

int? _recordRegionBoundary(Uint8List body) {
  int? prevStart, prevLen;
  var chainStart = -1;
  var chainCount = 0;
  var runStart = -1;
  final length = body.length;
  for (var byteIndex = 0; byteIndex <= length; byteIndex++) {
    if (byteIndex < length && isBinaryPrintable(body[byteIndex])) {
      if (runStart < 0) runStart = byteIndex;
      continue;
    }
    if (runStart >= 0) {
      final len = byteIndex - runStart;
      if (len >= _minRunLength) {
        if (prevStart != null && runStart == prevStart + prevLen! + 1) {
          chainCount++;
        } else {
          chainStart = runStart;
          chainCount = 1;
        }
        if (chainCount >= _boundaryChainMin) return chainStart;
        prevStart = runStart;
        prevLen = len;
      }
      runStart = -1;
    }
  }
  return null;
}

int? _firstTableOffset(
  List<BinaryString> runs, {
  int chainMin = _boundaryChainMin,
}) {
  var chainStart = -1;
  var len = 0;
  for (var runIndex = 0; runIndex < runs.length; runIndex++) {
    if (runIndex > 0) {
      final prev = runs[runIndex - 1];
      if (_packedAfter(prev, runs[runIndex])) {
        len++;
        continue;
      }
      if (len >= chainMin) return chainStart;
    }
    chainStart = runs[runIndex].offset;
    len = 1;
  }
  return len >= chainMin ? chainStart : null;
}

int _countSentinels(Uint8List bytes, int end) {
  final limit = end < bytes.length ? end : bytes.length;
  final view = ByteData.sublistView(bytes);
  var count = 0;
  for (var byteOffset = 0; byteOffset + _u32Bytes <= limit; byteOffset += _u32Bytes) {
    if (view.getUint32(byteOffset, Endian.little) == _sentinelWord) count++;
  }
  return count;
}

List<BinaryString> binaryStringTable(
  Uint8List seqBytes, {
  int minLength = _minRunLength,
}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return _stringTableFromBody(body, minLength: minLength);
}

List<BinaryString> _stringTableFromBody(
  Uint8List body, {
  int minLength = _minRunLength,
}) => _stringTableFromRuns(binaryStrings(body, minLength: minLength));

List<BinaryString> _stringTableFromRuns(List<BinaryString> runs) {
  var best = const <BinaryString>[];
  for (final chain in _segmentsFrom(runs, 0, minChain: 1)) {
    if (chain.length > best.length) best = chain;
  }
  return best.length >= _minTableEntries ? best : const [];
}

class BinaryAnalysis {
  const BinaryAnalysis({
    required this.inflatedSize,
    required this.strings,
    required this.stringTable,
    required this.layout,
    required this.nameTable,
    this.objectNames = const [],
    this.modulePaths = const [],
    this.stepReferences = const [],
    this.expressions = const [],
    this.quotedLiterals = const [],
    this.namedScalars = const [],
    this.scalarDoubles = const [],
    this.namedRecords = const [],
  });

  final int inflatedSize;

  final List<BinaryString> strings;

  final List<BinaryString> stringTable;

  final BinaryBodyLayout? layout;

  final List<BinaryString> nameTable;

  final List<String> objectNames;

  final List<String> modulePaths;

  final List<String> stepReferences;

  final List<String> expressions;

  final List<String> quotedLiterals;

  final List<BinaryNamedScalar> namedScalars;

  final List<double> scalarDoubles;

  final List<BinaryNamedRecord> namedRecords;
}

BinaryAnalysis? analyzeBinary(Uint8List seqBytes, {Uint8List? body}) {
  body ??= inflateBinaryBody(seqBytes);
  if (body == null) return null;
  final strings = binaryStrings(body, minLength: _poolMinRunLength);
  final runs = [
    for (final run in strings)
      if (run.text.length >= _minRunLength) run,
  ];
  final segments = _segmentsFromRuns(runs);
  final nameTable = _nameTableFromSegments(segments)?.entries ?? const [];
  final layout = _layoutFromRuns(body, runs);
  return BinaryAnalysis(
    inflatedSize: body.length,
    strings: strings,
    stringTable: _stringTableFromRuns(runs),
    layout: layout,
    nameTable: nameTable,
    objectNames: _objectNamesFrom([for (final entry in nameTable) entry.text]),
    modulePaths: _poolWhereFrom(segments, isBinaryModulePath),
    stepReferences: _poolWhereFrom(segments, _isStepRef),
    expressions: _poolWhereFrom(segments, isBinaryExpression),
    quotedLiterals: _poolWhereFrom(segments, isBinaryQuotedLiteral),
    namedScalars: layout == null ? const [] : _namedScalarsFromBody(body, layout.recordRegionLength),
    scalarDoubles: layout == null ? const [] : _scalarDoublesFromBody(body, layout.recordRegionLength),
    namedRecords: layout == null ? const [] : _namedRecordsFromBody(body, layout.recordRegionLength),
  );
}

class _BodyDecode {
  const _BodyDecode(this.body, this.boundary, this.pool, this.stream);

  final Uint8List body;

  final int boundary;

  final List<String> pool;

  final _RecordingDecodeSink stream;
}

_BodyDecode? _decodeSeq(Uint8List seqBytes) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return null;
  return _decodeBody(body);
}

_BodyDecode? _decodeBody(Uint8List body) {
  final recordRegionLength = _recordRegionBoundary(body);
  if (recordRegionLength == null) return null;
  final sink = _RecordingDecodeSink();
  final pool = _orderedStringPool(body, recordRegionLength);
  if (pool.isEmpty) return _BodyDecode(body, recordRegionLength, pool, sink);
  final view = ByteData.sublistView(body);

  sink.claim(0, _leadingWordCount * _u32Bytes, _tierStructural);
  sink.copy(0, _leadingWordCount * _u32Bytes);

  final bodyOffsets = <String, int>{};
  final headOffsets = <String, int>{};
  final tripleOffsets = <String, int>{};
  final records = _typeRecordsFromBody(
    body,
    recordRegionLength,
    sharedPool: pool,
    bodyOffsetsOut: bodyOffsets,
    headOffsetsOut: headOffsets,
    tripleOffsetsOut: tripleOffsets,
    decodeBodies: false,
  );
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, records);
  for (var recordIndex = 0; recordIndex < records.length; recordIndex++) {
    final record = records[recordIndex];
    final headAt = headOffsets[record.name];
    final tripleAt = tripleOffsets[record.name];
    if (headAt == null || tripleAt == null) continue;
    final bodyAt = bodyOffsets[record.name];
    final headStart = headAt >= _u32Bytes ? headAt - _u32Bytes : headAt;
    sink.claim(headStart, headAt + _typeStampOffset + _u32Bytes, _tierSemantic);
    if (tripleAt > _typeStampOffset + _u32Bytes) {
      sink.claim(headAt + _typeStampOffset + _u32Bytes, headAt + tripleAt, _tierStructural);
    }
    final headEnd = bodyAt ?? headAt + tripleAt + _typeVersionTripleWords * _u32Bytes;
    sink.claim(headAt + tripleAt, headEnd, _tierSemantic);
    if (headAt >= _u32Bytes) {
      final classWord = view.getUint32(headAt - _u32Bytes, Endian.little);
      if (classWord > 0 && classWord < pool.length && pool[classWord].isNotEmpty) {
        sink.poolRef(headAt - _u32Bytes, classWord);
      } else {
        sink.u32(headAt - _u32Bytes, classWord, _OpSource.struct);
      }
    }
    sink.poolRef(headAt, view.getUint32(headAt, Endian.little));
    sink.u32(headAt + _u32Bytes, record.typeCategory, _OpSource.model);
    sink.u32(headAt + _typeStampOffset, record.timestamp, _OpSource.model);
    if (tripleAt > _typeStampOffset + _u32Bytes) {
      sink.copy(headAt + _typeStampOffset + _u32Bytes, headAt + tripleAt);
    }
    for (var wordIndex = 0; wordIndex < _typeVersionTripleWords; wordIndex++) {
      final wordAt = headAt + tripleAt + wordIndex * _u32Bytes;
      sink.poolRef(wordAt, view.getUint32(wordAt, Endian.little));
    }
    final tailAt = headAt + tripleAt + _typeVersionTripleWords * _u32Bytes;
    if (bodyAt != null &&
        bodyAt >= _u32Bytes &&
        view.getUint32(bodyAt - _u32Bytes, Endian.little) == _recordDelimiter) {
      final flagsEnd = tailAt + record.flags.length * _u32Bytes;
      for (var wordOffset = tailAt; wordOffset + _u32Bytes <= headEnd; wordOffset += _u32Bytes) {
        final word = view.getUint32(wordOffset, Endian.little);
        if (wordOffset < flagsEnd) {
          sink.u32(wordOffset, word, _OpSource.model);
        } else if (word == 0 || word == _recordDelimiter) {
          sink.u32(wordOffset, word, _OpSource.grammar);
        } else {
          sink.u32(wordOffset, word, _OpSource.struct);
        }
      }
    } else if (bodyAt != null) {
      sink.u32(tailAt, 1, _OpSource.grammar);
      sink.poolRef(tailAt + _u32Bytes, view.getUint32(tailAt + _u32Bytes, Endian.little));
    }
    final nextHeadAt = recordIndex + 1 < records.length ? headOffsets[records[recordIndex + 1].name] : null;
    if (nextHeadAt != null && nextHeadAt >= _u32Bytes + _typeRecordPreambleBytes) {
      sink.claim(nextHeadAt - _u32Bytes - _typeRecordPreambleBytes, nextHeadAt - _u32Bytes, _tierStructural);
      sink.copy(nextHeadAt - _u32Bytes - _typeRecordPreambleBytes, nextHeadAt - _u32Bytes);
    }
    if (bodyAt == null) continue;
    final boundary = nextHeadAt != null ? nextHeadAt - _u32Bytes - _typeRecordPreambleBytes : null;
    final parser = _TypeBodyParser(view, pool, recordRegionLength, records, boundary, typeIndexBase)..ops = sink;
    final mBody = sink.mark();
    if (parser.parse(bodyAt) != null) {
      sink.claim(bodyAt, parser.lastEndOffset!, _tierSemantic);
    } else {
      sink.rollback(mBody);
    }
  }

  _sequenceOutlinesFromBody(body, recordRegionLength, pool, [for (final record in records) record.name], records, sink);

  for (final record in _propertyRecordsFromBody(body, recordRegionLength, pool)) {
    sink.claim(record.offset, record.offset + record.length, _tierSemantic);
    _leafPropertyRecordOps(sink, view, record);
  }

  for (final (start, end) in sink.blobSpans) {
    sink.demote(start, end);
  }
  return _BodyDecode(body, recordRegionLength, pool, sink);
}
