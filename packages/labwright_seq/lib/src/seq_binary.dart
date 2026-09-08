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
  for (var o = 0; o < input.length && !sink.overflowed; o += chunk) {
    final end = o + chunk < input.length ? o + chunk : input.length;
    decoderInput.add(Uint8List.sublistView(input, o, end));
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
  final stringCount = runs.where((r) => r.offset >= boundary).length;
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
  for (var i = 0; i + _u32Bytes <= recordRegionLength; i += _u32Bytes) {
    out.add(view.getUint32(i, Endian.little));
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
  for (var i = 0; i + _f64Bytes <= recordRegionLength; i += _u32Bytes) {
    if (view.getUint32(i, Endian.little) != 0) continue;
    final value = view.getFloat64(i, Endian.little);
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
    counts.update(name, (v) => v + 1, ifAbsent: () => 1);
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
  out.sort((a, b) => b.count.compareTo(a.count));
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
const _propRecordFlagsWidth = 1;
const _propTerminatorWidth = 2;

const _propMinKind = 2;
const _propMaxLeafKind = 14;

const _propLeafTypeNames = {'Bool', 'Num', 'Str', 'Path', 'Expr', 'Obj', 'Objs'};

const _propScalarKind = 6;

class BinaryPropertyRecord {
  const BinaryPropertyRecord({
    required this.name,
    required this.typeName,
    required this.value,
    required this.offset,
    required this.length,
    this.lead = 0,
    this.flagsByte = 0,
    this.kind = 0,
  });

  final String name;

  final String typeName;

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
  var at = recordRegionLength;
  while (at < body.length) {
    final start = at;
    while (at < body.length && body[at] != 0) {
      at++;
    }
    pool.add(String.fromCharCodes(body, start, at));
    at++;
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

  int wordAt(int at) => view.getUint32(at, Endian.little);
  final out = <BinaryPropertyRecord>[];

  var at = 0;
  while (at < recordRegionLength) {
    if (at + _u32Bytes <= recordRegionLength && wordAt(at) == _recordDelimiter) {
      at += _u32Bytes;
      continue;
    }
    final headerEnd = at + _PropRecordField.value.offset;
    if (_propRecordLeads.contains(body[at + _PropRecordField.lead.offset]) && headerEnd <= recordRegionLength) {
      final kind = wordAt(at + _PropRecordField.kind.offset);
      final typeIndex = wordAt(at + _PropRecordField.typeNameIndex.offset);
      final nameIndex = wordAt(at + _PropRecordField.nameIndex.offset);
      final framed =
          wordAt(at + _PropRecordField.zeroA.offset) == 0 &&
          wordAt(at + _PropRecordField.zeroB.offset) == 0 &&
          kind >= _propMinKind &&
          kind <= _propMaxLeafKind &&
          typeIndex < pool.length &&
          nameIndex < pool.length &&
          _propLeafTypeNames.contains(pool[typeIndex]);
      if (framed) {
        final typeName = pool[typeIndex];
        var consumed = _PropRecordField.value.offset;
        Object? value;
        if (kind >= _propScalarKind) {
          final valueAt = at + _PropRecordField.value.offset;
          switch (typeName) {
            case 'Str' || 'Path' || 'Expr':
              if (valueAt + _u32Bytes <= recordRegionLength) {
                final poolIndex = wordAt(valueAt);
                if (poolIndex < pool.length) value = pool[poolIndex];
                consumed += _u32Bytes;
              }
            case 'Bool':
              if (valueAt < recordRegionLength) {
                value = body[valueAt] != 0;
                consumed += _propRecordFlagsWidth;
              }
            case 'Num':
              if (valueAt + _f64Bytes <= recordRegionLength) {
                value = view.getFloat64(valueAt, Endian.little);
                consumed += _f64Bytes;
              }
          }
        }
        if (at + consumed + _propTerminatorWidth <= recordRegionLength &&
            body[at + consumed] == 0 &&
            body[at + consumed + 1] == 0) {
          consumed += _propTerminatorWidth;
        }
        out.add(
          BinaryPropertyRecord(
            name: pool[nameIndex],
            typeName: typeName,
            value: value,
            offset: at,
            length: consumed,
            lead: body[at + _PropRecordField.lead.offset],
            flagsByte: body[at + _PropRecordField.lead.offset + 1],
            kind: kind,
          ),
        );
        at += consumed;
        continue;
      }
    }
    at++;
  }
  return out;
}

const _maxDeclarationPathWords = 8;

(List<String>, int)? _objectDeclarationPath(
  Uint8List body,
  ByteData view,
  List<String> pool,
  int at,
  int recordRegionLength,
) {
  if (at + _PropRecordField.zeroA.offset + _u32Bytes > recordRegionLength) return null;
  if (!_propRecordLeads.contains(body[at + _PropRecordField.lead.offset])) return null;
  if (body[at + 1] != 0) return null;
  final firstOffset = at + _PropRecordField.zeroA.offset;
  final first = view.getUint32(firstOffset, Endian.little);
  if (first == 0 || first >= pool.length || pool[first].isEmpty) return null;

  final path = <String>[];
  var offset = firstOffset;
  while (offset + _u32Bytes <= recordRegionLength && path.length < _maxDeclarationPathWords) {
    final word = view.getUint32(offset, Endian.little);
    if (word == 0) {
      offset += _u32Bytes;
      continue;
    }
    if (word < pool.length && pool[word].isNotEmpty) {
      path.add(pool[word]);
      offset += _u32Bytes;
    } else {
      break;
    }
  }
  return (path, offset);
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
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final decl = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
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
  for (var i = 0; i < table.length; i++) {
    if (table[i].name == 'Expression') exprIdx.add(i);
  }
  if (exprIdx.isEmpty) return 0;
  const framedValued = _fieldFramedBit | _fieldHasValueBit;
  Set<int>? common;
  var anchorSites = 0;
  for (var at = 0; at + 6 * _u32Bytes <= recordRegionLength; at++) {
    final flags = view.getUint32(at, Endian.little);
    if (flags & framedValued != framedValued || flags & ~_fieldKnownFlagBits != 0) continue;
    if (view.getUint32(at + _u32Bytes, Endian.little) != 0) continue;
    if (view.getUint32(at + 2 * _u32Bytes, Endian.little) != _recordDelimiter) continue;
    final nameWord = view.getUint32(at + 4 * _u32Bytes, Endian.little);
    if (nameWord == 0 || nameWord >= pool.length || !_typeIndexAnchorFields.contains(pool[nameWord])) {
      continue;
    }
    final x = view.getUint32(at + 3 * _u32Bytes, Endian.little);
    if (x < 1) continue;
    final cands = {for (final e in exprIdx) x - 1 - e};
    common = common == null ? cands : common.intersection(cands);
    if (common.isEmpty) return 0;
    anchorSites++;
  }
  if (common == null) return 0;
  final base = common.reduce((a, b) => a.abs() < b.abs() ? a : b);
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

  bool _validTableX(int x) {
    final i = x - 1 - typeIndexBase;
    return i >= 0 && i < table.length;
  }

  BinaryTypeRecord _tableRef(int x) => table[x - 1 - typeIndexBase];

  final int? bodyEndBoundary;

  int _u32(int at) => view.getUint32(at, Endian.little);
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
    var at = from;
    for (var i = 0; i <= _fieldMaxAttrWords; i++) {
      if (at + _u32Bytes > recordRegionLength) return _blockBail(rollbackMark);
      final word = _u32(at);
      if (word == 0 && i >= minWords) {
        ops.u32(at, 0, _OpSource.grammar);
        return at + _u32Bytes;
      }
      if (attrsOut != null) {
        attrsOut.add(word);
        ops.u32(at, word, _OpSource.model);
      } else {
        ops.u32(at, word, _OpSource.struct);
      }
      at += _u32Bytes;
    }
    return _blockBail(rollbackMark);
  }

  /// TODO: only the extent is walked; spec contents are not decoded.
  int? _elementSpec(int at) {
    final rollbackMark = ops.mark();
    final end = _elementSpecWalk(at);
    ops.rollback(rollbackMark);
    return end;
  }

  int? _elementSpecWalk(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    if (view.getUint8(p) == 0) p++;
    if (!_canRead(p) || _u32(p) != _recordDelimiter) return null;
    p += _u32Bytes;
    if (!_canRead(p)) return null;
    final x = _u32(p);
    var xOmitted = false;
    if (x == _recordDelimiter) {
      xOmitted = true;
      p += _u32Bytes;
    } else {
      if (!_validTableX(x)) return null;
      p += _u32Bytes;
      if (!_canRead(p) || _u32(p) != _recordDelimiter) return null;
      p += _u32Bytes;
    }
    if (!_canRead(p)) return null;
    var tagged = false;
    if (_tok(_u32(p)) != null && p + 2 * _u32Bytes <= recordRegionLength && _u32(p + _u32Bytes) == 0x20000) {
      p += _u32Bytes;
    }
    if (_u32(p) == 0x20000) {
      tagged = true;
      p += _u32Bytes;
      if (!_canRead(p)) return null;
    }
    final count = _u32(p);
    if ((count < 1 && !tagged && xOmitted) || count > _typeMaxFields) return null;
    p += _u32Bytes;
    final items = _fields(p, count);
    if (items == null) return null;
    return _attrTail(items.$2);
  }

  bool _canRead(int at) => at + _u32Bytes <= recordRegionLength;

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
    final lb = _boundDims(lbound);
    final ub = _boundDims(ubound);
    if (lb == null || ub == null || lb.length != ub.length) return null;
    var count = 1;
    for (var i = 0; i < lb.length; i++) {
      if (ub[i] < lb[i]) return null;
      count *= ub[i] - lb[i] + 1;
      if (count > _maxArrayElements) return null;
    }
    return count;
  }

  (List<BinaryTypeField>, int)? _stepElementPrefix(int at, int count) {
    final elements = <BinaryTypeField>[];
    var p = at;
    for (var i = 0; i < count; i++) {
      final rollbackMark = ops.mark();
      final element = _arrayElement(p);
      if (element == null || element.$1.valueClass != SeqValueClass.step) {
        ops.rollback(rollbackMark);
        break;
      }
      elements.add(element.$1);
      p = element.$2;
    }
    if (elements.isEmpty) return null;
    return (elements, p);
  }

  (List<BinaryTypeField>, int)? _populatedArrayTail(int at, String lbound, String ubound, {List<int>? attrsOut}) {
    _lastArrayPartial = false;
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (_inInstance) {
      if (at < recordRegionLength && view.getUint8(at) == 0) {
        for (final start in _protoSpecEnds(at + 1)) {
          final rollbackMark = ops.mark();
          final attrsMark = attrsOut?.length;
          ops.byte(at, 0, _OpSource.grammar);
          ops.copy(at + 1, start);
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
    final tail = _attrTail(at, attrsOut: attrsOut);
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

  List<int> _protoSpecEnds(int at) {
    final ends = <int>[];
    final six = _protoSpec(at);
    if (six != null) ends.add(six);
    var p = at;
    if (p < recordRegionLength && view.getUint8(p) == 0) p++;
    if (p + 5 * _u32Bytes <= recordRegionLength &&
        _u32(p) == _recordDelimiter &&
        _u32(p + _u32Bytes) == _recordDelimiter &&
        _tok(_u32(p + 2 * _u32Bytes)) != null &&
        _u32(p + 3 * _u32Bytes) == 0 &&
        _u32(p + 4 * _u32Bytes) == 0) {
      final five = p + 5 * _u32Bytes;
      if (!ends.contains(five)) ends.add(five);
    }
    ends.add(at);
    return ends;
  }

  (List<BinaryTypeField>, int)? _scalarArrayTail(int at, String lbound, String ubound, {List<int>? attrsOut}) {
    final count = _boundCount(lbound, ubound);
    if (count == null) return null;
    if (at + count * _f64Bytes > recordRegionLength) return null;
    final rollbackMark = ops.mark();
    final elements = <BinaryTypeField>[];
    var p = at;
    for (var i = 0; i < count; i++, p += _f64Bytes) {
      final value = view.getFloat64(p, Endian.little);
      if (!value.isFinite || (value != 0 && value.abs() < _smallestNormalF64)) {
        return _blockBail(rollbackMark);
      }
      ops.f64(p, value);
      final text = value == value.truncateToDouble() && value.abs() < 1e15 ? '${value.truncate()}' : '$value';
      elements.add(BinaryTypeField('', className: SeqValueClass.number.wire, value: text));
    }
    final attrsMark = attrsOut?.length;
    final after = _attrTail(p, attrsOut: attrsOut);
    if (after == null) {
      ops.rollback(rollbackMark);
      if (attrsMark != null) attrsOut!.length = attrsMark;
      return null;
    }
    return (elements, after);
  }

  (String, int)? _elemProtoTail(int at) {
    if (at + 3 * _u32Bytes > recordRegionLength) return null;
    final cls = _tok(_u32(at));
    if (cls == null) return null;
    if (_u32(at + _u32Bytes) != _recordDelimiter) return null;
    if (_u32(at + 2 * _u32Bytes) != 0) return null;
    final rollbackMark = ops.mark();
    final after = _attrTail(at + 3 * _u32Bytes);
    ops.rollback(rollbackMark);
    if (after == null) return null;
    return (cls, after);
  }

  (List<BinaryTypeField>, int)? _elementRun(int at, int count) {
    final rollbackMark = ops.mark();
    var p = at;
    final elements = <BinaryTypeField>[];
    for (var i = 0; i < count; i++) {
      final element = _arrayElement(p);
      if (element == null) return _blockBail(rollbackMark);
      elements.add(element.$1);
      p = element.$2;
    }
    return (elements, p);
  }

  int? _protoSpec(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    if (view.getUint8(p) == 0) p++;
    if (p + 6 * _u32Bytes > recordRegionLength) return null;
    if (_u32(p) != _recordDelimiter || _u32(p + _u32Bytes) != _recordDelimiter) {
      return null;
    }
    final value = _u32(p + 2 * _u32Bytes);
    if (value != 0 && _tok(value) == null) return null;
    if (_u32(p + 3 * _u32Bytes) != 0) return null;
    if (_u32(p + 5 * _u32Bytes) != 0) return null;
    if (value == 0 && _u32(p + 4 * _u32Bytes) == 0) return null;
    return p + 6 * _u32Bytes;
  }

  (BinaryTypeField, int)? _arrayElement(int at) {
    for (final start in [at, if (at < recordRegionLength && view.getUint8(at) == 0) at + 1]) {
      if (!_canRead(start) || _u32(start) != _recordDelimiter) continue;
      final rollbackMark = ops.mark();
      if (start > at) ops.byte(at, 0, _OpSource.grammar);
      final block = _elementBlock(start);
      if (block == null) ops.rollback(rollbackMark);
      return block;
    }
    if (!_canRead(at)) return null;
    if (_tok(_u32(at)) == _stepToken) return _stepElement(at);
    final outer = _inInstance;
    _inInstance = true;
    final field = _field(at);
    _inInstance = outer;
    return field;
  }

  (BinaryTypeField, int)? _stepElement(int at) {
    if (at + 4 * _u32Bytes > recordRegionLength) return null;
    if (_tok(_u32(at)) != 'Step') return null;
    final x = _u32(at + _u32Bytes);
    if (!_validTableX(x)) return null;
    final name = _tok(_u32(at + 2 * _u32Bytes));
    if (name == null) return null;
    final count = _u32(at + 3 * _u32Bytes);
    if (count > _typeMaxFields) return null;
    final ref = _tableRef(x);
    final rollbackMark = ops.mark();
    ops.poolRef(at, _u32(at));
    ops.u32(at + _u32Bytes, x, _OpSource.model);
    ops.poolRef(at + 2 * _u32Bytes, _u32(at + 2 * _u32Bytes));
    ops.u32(at + 3 * _u32Bytes, count, _OpSource.model);
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = _reprsOf(ref);
    final children = _fields(at + 4 * _u32Bytes, count);
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

  (BinaryTypeField, int)? _elementBlock(int at) {
    final rollbackMark = ops.mark();
    ops.u32(at, _recordDelimiter, _OpSource.grammar);
    var p = at + _u32Bytes;
    if (!_canRead(p)) return _blockBail(rollbackMark);
    final x = _u32(p);
    p += _u32Bytes;
    if (!_canRead(p)) return _blockBail(rollbackMark);
    final word3 = _u32(p);
    var name = '';
    BinaryTypeRecord? ref;
    if (word3 == _recordDelimiter) {
      if (!_validTableX(x)) return _blockBail(rollbackMark);
      ref = _tableRef(x);
      ops.u32(at + _u32Bytes, x, _OpSource.model);
      ops.u32(p, _recordDelimiter, _OpSource.grammar);
      final word4At = p + _u32Bytes;
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
      if (named == null || x == 0 || _tok(x) == null) return _blockBail(rollbackMark);
      name = named;
      ops.poolRef(at + _u32Bytes, x);
      ops.poolRef(p, word3);
    }
    p += _u32Bytes;
    if (!_canRead(p)) return _blockBail(rollbackMark);
    final count = _u32(p);
    if (count > _typeMaxFields) return _blockBail(rollbackMark);
    ops.u32(p, count, _OpSource.model);
    p += _u32Bytes;
    final outerInstance = _inInstance;
    final outerRepr = _numericReprContext;
    _inInstance = true;
    _numericReprContext = ref != null ? _reprsOf(ref) : null;
    final children = _fields(p, count);
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
  int? _extBlocksFrom(int at, int remaining) {
    if (remaining == 0) return at;
    if (at + 10 > recordRegionLength) return null;
    if (_tok(_u32(at)) == null) return null;
    final slotAt = at + _u32Bytes + 2;
    if (slotAt + _u32Bytes <= recordRegionLength) {
      final slot = _u32(slotAt);
      if (slot == _recordDelimiter || _tok(slot) != null) {
        final rest = _extBlocksFrom(slotAt + _u32Bytes, remaining - 1);
        if (rest != null) return rest;
      }
    }
    final structEnd = at + _u32Bytes + 2 + 20;
    if (structEnd > recordRegionLength) return null;
    return _extBlocksFrom(structEnd, remaining - 1);
  }

  int? _extTail(int from) {
    var p = from;
    for (var k = 0; k <= _fieldMaxAttrWords; k++, p += _u32Bytes) {
      if (p + _u32Bytes > recordRegionLength) return null;
      final count = _u32(p);
      if (count == 0) return null;
      if (count <= _typeMaxExtBlocks) {
        final end = _extBlocksFrom(p + _u32Bytes, count);
        if (end != null && end + _u32Bytes <= recordRegionLength && _u32(end) == 0) {
          ops.blob(p, end);
          for (var q = from; q < p; q += _u32Bytes) {
            ops.u32(q, _u32(q), _OpSource.struct);
          }
          ops.u32(p, count, _OpSource.struct);
          ops.copy(p + _u32Bytes, end);
          ops.u32(end, 0, _OpSource.grammar);
          return end + _u32Bytes;
        }
      }
    }
    return null;
  }

  int? _refSpec(int at) {
    var p = at;
    if (p >= recordRegionLength) return null;
    if (view.getUint8(p) == 0) p++;
    if (p + 5 * _u32Bytes > recordRegionLength || _u32(p) != _recordDelimiter) {
      return null;
    }
    if (_u32(p + _u32Bytes) == 0) return null;
    for (var i = 2; i < 5; i++) {
      if (_u32(p + i * _u32Bytes) != 0) return null;
    }
    return p + 5 * _u32Bytes;
  }

  int? lastFieldOffset;

  int? lastEndOffset;

  List<(BinaryTypeField, int)> parseLeadingSubProps(int at, int max, Set<String> groupNames) {
    _usedSpec = false;
    _depth = 0;
    final fields = <(BinaryTypeField, int)>[];
    var cur = at;
    for (var i = 0; i < max; i++) {
      if (cur + 4 * _u32Bytes <= recordRegionLength) {
        final cls = _tok(_u32(cur + 2 * _u32Bytes));
        final nm = _tok(_u32(cur + 3 * _u32Bytes));
        if (cls == 'Objs' && nm != null && groupNames.contains(nm)) {
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

  (BinaryTypeField, int)? parseFieldAt(int at) {
    _usedSpec = false;
    _depth = 0;
    final parsed = _field(at);
    if (parsed != null) lastEndOffset = parsed.$2;
    return parsed;
  }

  ({List<BinaryTypeField> fields, int? end}) parseStepTs(int at) {
    const none = (fields: <BinaryTypeField>[], end: null);
    if (at + 5 * _u32Bytes > recordRegionLength) return none;
    if (_u32(at) != 0 || _u32(at + _u32Bytes) != 0 || _u32(at + 2 * _u32Bytes) != _recordDelimiter) {
      return none;
    }
    if (_tok(_u32(at + 3 * _u32Bytes)) != 'TS') return none;
    final fullMark = ops.mark();
    if (parseFieldAt(at) case (final full, final end) when full.name == 'TS' && full.children.isNotEmpty) {
      return (fields: full.children, end: end);
    }
    ops.rollback(fullMark);
    final idMark = ops.mark();
    if (parseFieldAt(at + 5 * _u32Bytes) case (final idField, final end)
        when idField.valueClass == SeqValueClass.string &&
            idField.name == 'Id' &&
            (idField.value?.startsWith('ID#:') ?? false)) {
      ops.u32(at, 0, _OpSource.grammar);
      ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
      ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
      ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
      ops.u32(at + 4 * _u32Bytes, _u32(at + 4 * _u32Bytes), _OpSource.model);
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
    var at = from;
    final fields = <BinaryTypeField>[];
    while (at < boundary && fields.length <= _typeMaxFields) {
      final parsed = _fields(at, 1);
      if (parsed == null) return _blockBail(rollbackMark);
      fields.addAll(parsed.$1);
      at = parsed.$2;
    }
    if (at != boundary) return _blockBail(rollbackMark);
    return (fields, at);
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
    var at = from;
    final fields = <BinaryTypeField>[];
    for (var i = 0; i < count; i++) {
      final field = _field(at);
      if (field == null) return null;
      at = field.$2;
      var specBytes = 0;
      if (field.$1.isArray && (field.$1.children.isEmpty || !_inInstance)) {
        while (true) {
          final specEnd = _elementSpec(at) ?? _refSpec(at) ?? _protoSpec(at);
          if (specEnd == null) break;
          ops.copy(at, specEnd);
          specBytes += specEnd - at;
          at = specEnd;
          _usedSpec = true;
        }
        if (specBytes == 0) {
          var lead = at;
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
    return (fields, at);
  }

  (BinaryTypeField, int)? _field(int at) {
    lastFieldOffset = at;
    return _trial(() => _fieldParse(at));
  }

  (BinaryTypeField, int)? _fieldParse(int at) {
    if (at + 6 * _u32Bytes > recordRegionLength) return null;
    final fieldFlags = _u32(at);
    return switch (_fieldFormAt(at, fieldFlags)) {
      _FieldForm.compact => _parseCompactField(at),
      _FieldForm.descriptor => _parseDescriptorField(at),
      _FieldForm.framed => _parseFramedField(at, fieldFlags),
      _FieldForm.framedLite => _parseFramedLiteField(at, fieldFlags),
      _FieldForm.plain => _parsePlainField(at, fieldFlags),
      null => null,
    };
  }

  _FieldForm? _fieldFormAt(int at, int fieldFlags) {
    if (_u32(at + _u32Bytes) != 0) return _FieldForm.compact;
    if (fieldFlags & ~_fieldKnownFlagBits != 0) return null;
    final delimited = _u32(at + 2 * _u32Bytes) == _recordDelimiter;
    if (fieldFlags == 0 && delimited) return _FieldForm.descriptor;
    if (fieldFlags & _fieldFramedBit != 0) return _FieldForm.framed;
    return delimited ? _FieldForm.framedLite : _FieldForm.plain;
  }

  (BinaryTypeField, int)? _parseCompactField(int at) {
    if (_inInstance) return null;
    final nameWord = _u32(at);
    final valueWord = _u32(at + _u32Bytes);
    final name = _tok(nameWord);
    final value = _tok(valueWord);
    if (name == null || value == null) return null;
    ops.poolRef(at, nameWord);
    ops.poolRef(at + _u32Bytes, valueWord);
    final attrs = <int>[];
    final after = _attrTail(at + 2 * _u32Bytes, attrsOut: attrs);
    if (after == null) return null;
    return (BinaryTypeField(name, value: value, attrWords: attrs), after);
  }

  (BinaryTypeField, int)? _parseDescriptorField(int at) {
    final name = _tok(_u32(at + 3 * _u32Bytes));
    if (name == null) return null;
    final childCount = _u32(at + 4 * _u32Bytes);
    if (childCount > _typeMaxFields) return null;
    ops.u32(at, 0, _OpSource.grammar);
    ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
    ops.u32(at + 4 * _u32Bytes, childCount, _OpSource.model);
    final children = _fields(at + 5 * _u32Bytes, childCount);
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

  (BinaryTypeField, int)? _parseFramedField(int at, int fieldFlags) {
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    if (hasNumericRep) return null;
    if (_u32(at + 2 * _u32Bytes) != _recordDelimiter) return null;
    final x = _u32(at + 3 * _u32Bytes);
    final nameWord = _u32(at + 4 * _u32Bytes);
    final name = nameWord == _recordDelimiter && _inInstance ? '' : _tok(nameWord);
    if (name == null) return null;
    ops.u32(at, fieldFlags, _OpSource.model);
    ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    if (nameWord == _recordDelimiter) {
      ops.u32(at + 4 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    } else {
      ops.poolRef(at + 4 * _u32Bytes, nameWord);
    }
    var next = at + 5 * _u32Bytes;
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
      ops.u32(at + 3 * _u32Bytes, x, _OpSource.model);
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
            intrinsicTypeId: x == 0 ? null : x,
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
          intrinsicTypeId: x == 0 ? null : x,
          children: elements.$1,
          fieldFlags: fieldFlags,
          attrWords: attrs,
        ),
        elements.$2,
      );
    }
    if (x == 0) {
      ops.u32(at + 3 * _u32Bytes, 0, _OpSource.grammar);
      if (valued) {
        value = _tok(_u32(next));
        if (value == null) return null;
        ops.poolRef(next, _u32(next));
        next += _u32Bytes;
      } else {
        value = _inInstance ? null : '';
      }
    } else if (x >= 1 && valued && _validTableX(x) && _tableRef(x).name == 'Expression') {
      value = _tok(_u32(next));
      if (value == null) return null;
      ops.u32(at + 3 * _u32Bytes, x, _OpSource.model);
      ops.poolRef(next, _u32(next));
      next += _u32Bytes;
    } else if (x >= 2 && !valued && _validTableX(x)) {
      final ref = _tableRef(x);
      ops.u32(at + 3 * _u32Bytes, x, _OpSource.model);
      for (var k = minAttrs; k <= _fieldMaxAttrWords; k++) {
        final countAt = next + k * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final word = _u32(countAt);
        if (word == 0) break;
        if (word < 1 || word > _typeMaxFields) continue;
        final mInst = ops.mark();
        final instAttrs = <int>[];
        for (var j = 0; j < k; j++) {
          instAttrs.add(_u32(next + j * _u32Bytes));
          ops.u32(next + j * _u32Bytes, instAttrs[j], _OpSource.model);
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
    } else if (x == 1 && !valued) {
      ops.u32(at + 3 * _u32Bytes, 1, _OpSource.grammar);
      final attrsFrom = next;
      next += minAttrs * _u32Bytes;
      if (next + _u32Bytes > recordRegionLength) return null;
      var overrideCount = _u32(next);
      for (var k = 0; overrideCount > _typeMaxFields && k < _fieldMaxAttrWords; k++) {
        next += _u32Bytes;
        if (next + _u32Bytes > recordRegionLength) return null;
        overrideCount = _u32(next);
      }
      if (overrideCount > _typeMaxFields) return null;
      final customAttrs = <int>[];
      for (var q = attrsFrom; q < next; q += _u32Bytes) {
        customAttrs.add(_u32(q));
        ops.u32(q, customAttrs.last, _OpSource.model);
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

  (BinaryTypeField, int)? _parseFramedLiteField(int at, int fieldFlags) {
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    if (hasNumericRep) return null;
    final name = _tok(_u32(at + 3 * _u32Bytes));
    if (name == null) return null;
    ops.u32(at, fieldFlags, _OpSource.model);
    ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
    ops.u32(at + 2 * _u32Bytes, _recordDelimiter, _OpSource.grammar);
    ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
    var next = at + 4 * _u32Bytes;
    if (!valued) {
      for (var k = minAttrs; k <= _fieldMaxAttrWords; k++) {
        final countAt = next + k * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final word = _u32(countAt);
        if (word == 0) break;
        if (word < 1 || word > _typeMaxFields) continue;
        final mObj = ops.mark();
        final objAttrs = <int>[];
        for (var j = 0; j < k; j++) {
          objAttrs.add(_u32(next + j * _u32Bytes));
          ops.u32(next + j * _u32Bytes, objAttrs[j], _OpSource.model);
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

  (BinaryTypeField, int)? _parsePlainField(int at, int fieldFlags) {
    final hasExtData = fieldFlags & _fieldHasExtDataBit != 0;
    final valued = fieldFlags & _fieldHasValueBit != 0;
    final hasFormat = fieldFlags & _fieldHasFormatBit != 0;
    final hasNumericRep = fieldFlags & _fieldHasNumericRepBit != 0;
    final minAttrs = _minAttrWords(fieldFlags);
    final className = _clsTok(_u32(at + 2 * _u32Bytes));
    final name = _tok(_u32(at + 3 * _u32Bytes));
    if (className == null || name == null) return null;
    final cls = SeqValueClass.from(className);
    ops.u32(at, fieldFlags, _OpSource.model);
    ops.u32(at + _u32Bytes, 0, _OpSource.grammar);
    ops.poolRef(at + 2 * _u32Bytes, _u32(at + 2 * _u32Bytes));
    ops.poolRef(at + 3 * _u32Bytes, _u32(at + 3 * _u32Bytes));
    var next = at + 4 * _u32Bytes;
    if (!valued && !_tailedValueClasses.contains(cls)) {
      if (hasNumericRep) return null;
      for (var k = 0; k <= _fieldMaxAttrWords; k++) {
        final countAt = next + k * _u32Bytes;
        if (countAt + _u32Bytes > recordRegionLength) break;
        final childCount = _u32(countAt);
        if (childCount > _typeMaxFields) continue;
        if (childCount == 0 && fieldFlags == 0x4 && countAt + 2 * _u32Bytes <= recordRegionLength) {
          final adjacent = _u32(countAt + _u32Bytes);
          if (adjacent >= 1 && adjacent <= _typeMaxFields) {
            final mAdj = ops.mark();
            final adjAttrs = <int>[];
            for (var j = 0; j < k; j++) {
              adjAttrs.add(_u32(next + j * _u32Bytes));
              ops.u32(next + j * _u32Bytes, adjAttrs[j], _OpSource.model);
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
        for (var j = 0; j < k; j++) {
          declAttrs.add(_u32(next + j * _u32Bytes));
          ops.u32(next + j * _u32Bytes, declAttrs[j], _OpSource.model);
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
        if (cls != SeqValueClass.number || !_canRead(next)) return null;
        repr = _u32(next);
        ops.u32(next, repr, _OpSource.model);
        next += _u32Bytes;
      }
      final attrs = <int>[];
      final after = hasExtData ? _extTail(next) : _attrTail(next, minWords: minAttrs, attrsOut: attrs);
      if (after == null) return null;
      if (!_unvaluedScalarClasses.contains(cls)) return null;
      return (
        BinaryTypeField(
          name,
          className: className,
          value: _inInstance || cls == SeqValueClass.reference
              ? null
              : switch (cls) {
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
    if (_boundedArrayClasses.contains(cls) &&
        next + 2 * _u32Bytes <= recordRegionLength &&
        _isBoundToken(_tok(_u32(next))) &&
        _isBoundToken(_tok(_u32(next + _u32Bytes)))) {
      if (hasNumericRep) return null;
      final lbound = _tok(_u32(next))!;
      final ubound = _tok(_u32(next + _u32Bytes))!;
      ops.poolRef(next, _u32(next));
      ops.poolRef(next + _u32Bytes, _u32(next + _u32Bytes));
      if (cls == SeqValueClass.objects && ubound != '[]') {
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
      if (cls == SeqValueClass.numbers && valued && ubound != '[]') {
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
      if (cls == SeqValueClass.objects) {
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
    switch (cls) {
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
  for (var at = 0; at + _typeRecordMinBytes <= recordRegionLength; at++) {
    final stamp = view.getUint32(at + _typeStampOffset, Endian.little);
    if (stamp < _typeStampMin || stamp > _typeStampMax) continue;
    final nameIndex = view.getUint32(at, Endian.little);
    if (nameIndex == 0 || nameIndex >= pool.length) continue;
    final name = pool[nameIndex];
    if (name.isEmpty || !_typeNamePattern.hasMatch(name)) continue;
    int? tripleAt;
    for (final tripleStart in _typeVersionTripleStarts) {
      if (at + tripleStart + _typeVersionTripleWords * _u32Bytes > recordRegionLength) {
        continue;
      }
      var triple = true;
      for (var i = 0; i < _typeVersionTripleWords; i++) {
        final word = view.getUint32(at + tripleStart + i * _u32Bytes, Endian.little);
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
    final classWord = at >= _u32Bytes ? view.getUint32(at - _u32Bytes, Endian.little) : null;
    final className = classWord == null
        ? null
        : classWord == 0
        ? (pool[0].isNotEmpty && _TypeBodyParser._rootClassPattern.hasMatch(pool[0]) ? pool[0] : null)
        : tok(classWord);
    final typeCategory = view.getUint32(at + _u32Bytes, Endian.little);
    final versions = [
      for (var i = 0; i < _typeVersionTripleWords; i++)
        pool[view.getUint32(at + tripleAt + i * _u32Bytes, Endian.little)],
    ];
    final flags = <int>[];
    var flagAt = at + tripleAt + _typeVersionTripleWords * _u32Bytes;
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
      final tailAt = at + tripleAt + _typeVersionTripleWords * _u32Bytes;
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
    headAts.add(at);
    if (bodyAt != null) bodyOffsetsOut?[name] = bodyAt;
    headOffsetsOut?[name] = at;
    tripleOffsetsOut?[name] = tripleAt;
  }
  if (!decodeBodies) return records;
  final result = List.of(records);
  final typeIndexBase = deriveTypeIndexBase(view, pool, recordRegionLength, result);
  for (var i = 0; i < result.length; i++) {
    final bodyAt = bodyOffsets[i];
    if (bodyAt == null) continue;
    final boundary = i + 1 < headAts.length ? headAts[i + 1] - _u32Bytes - _typeRecordPreambleBytes : null;
    final fields = _TypeBodyParser(view, pool, recordRegionLength, result, boundary, typeIndexBase).parse(bodyAt);
    result[i] = BinaryTypeRecord(
      name: records[i].name,
      className: records[i].className,
      typeCategory: records[i].typeCategory,
      timestamp: records[i].timestamp,
      versions: records[i].versions,
      flags: records[i].flags,
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
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    final bodyAt = bodyOffsets[record.name];
    if (bodyAt == null) continue;
    final boundary = i + 1 < records.length
        ? (headOffsets[records[i + 1].name] ?? 0) - _u32Bytes - _typeRecordPreambleBytes
        : null;
    final parser = _TypeBodyParser(view, pool, recordRegionLength, records, boundary, typeIndexBase);
    final ok = parser.parse(bodyAt) != null;
    extents.add((
      name: record.name,
      headAt: headOffsets[record.name] ?? -1,
      bodyAt: bodyAt,
      end: ok ? parser.lastEndOffset : null,
      bail: ok ? null : parser.lastFieldOffset ?? -1,
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
  int wordAt(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;

  final seen = <String>{};
  final names = <String>[];
  for (var at = 0; at + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; at++) {
    if (wordAt(at) != stepToken) continue;
    final kind = poolAt(wordAt(at + _u32Bytes));
    final name = poolAt(wordAt(at + _stepNameWordGap * _u32Bytes));
    final container = poolAt(wordAt(at + (_stepNameWordGap + 1) * _u32Bytes));
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
    for (var i = 1; i < pool.length; i++)
      if (pool[i] == 'Sequence') i,
  };
  if (seqIdx.isEmpty) return const [];
  int u32(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int word) => word > 0 && word < pool.length && pool[word].isNotEmpty ? pool[word] : null;
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)
    ..ops = sink
    .._partialStepArraysOk = true;

  (List<(BinaryTypeField, int)>, int) walkSubProps(int from, int count) {
    final subProps = <(BinaryTypeField, int)>[];
    final seenTail = <String>{};
    var cur = from;
    while (subProps.length < count) {
      final i = subProps.length;
      final mField = sink.mark();
      final parsed = parser.parseFieldAt(cur);
      if (parsed == null) break;
      final (field, fieldEnd) = parsed;
      var gated = false;
      if (i < _sequenceSubPropHead.length) {
        gated = field.name != _sequenceSubPropHead[i];
      } else {
        gated = !_sequenceSubPropTailNames.contains(field.name) || !seenTail.add(field.name);
      }
      if (!gated) gated = field.valueClass != _sequenceSubPropClasses[field.name];
      if (!gated &&
          _stepGroupNames.contains(field.name) &&
          field.children.any((c) => c.valueClass != SeqValueClass.step)) {
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
  var at = 0;
  while (at + 3 * _u32Bytes <= recordRegionLength) {
    if (!seqIdx.contains(u32(at))) {
      at++;
      continue;
    }
    final name = poolAt(u32(at + _u32Bytes));
    if (name == null) {
      at++;
      continue;
    }
    _SequenceRecordWalk? walked;
    for (final withComment in const [false, true]) {
      final countAt = at + (withComment ? 3 : 2) * _u32Bytes;
      if (countAt + _u32Bytes > recordRegionLength) continue;
      final count = u32(countAt);
      if (count < 1 || count > _sequenceRecordMaxSubProps) continue;
      final mCand = sink.mark();
      final (subProps, end) = walkSubProps(countAt + _u32Bytes, count);
      if (subProps.isEmpty || subProps.first.$1.name != 'Parameters') {
        sink.rollback(mCand);
        continue;
      }
      final commentWord = withComment ? u32(at + 2 * _u32Bytes) : 0;
      final comment = withComment && commentWord > _sequenceRecordMaxSubProps ? poolAt(commentWord) : null;
      sink.poolRef(at, u32(at));
      sink.poolRef(at + _u32Bytes, u32(at + _u32Bytes));
      if (withComment) {
        if (comment != null) {
          sink.poolRef(at + 2 * _u32Bytes, commentWord);
        } else {
          sink.u32(at + 2 * _u32Bytes, commentWord, _OpSource.struct);
        }
      }
      sink.u32(countAt, count, _OpSource.model);
      walked = _SequenceRecordWalk(at, name, comment, withComment ? 4 : 3, count, subProps, end);
      break;
    }
    if (walked == null) {
      at++;
      continue;
    }
    walks.add(walked);
    sink.claim(at, at + walked.headWords * _u32Bytes, _tierSemantic);
    var fieldStart = at + walked.headWords * _u32Bytes;
    for (final (_, fieldEnd) in walked.subProps) {
      sink.claim(fieldStart, fieldEnd, _tierSemantic);
      fieldStart = fieldEnd;
    }
    at = walked.end > at ? walked.end : at + 1;
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
  for (var at = 0; at + _minDeclarationBytes <= recordRegionLength; at++) {
    final decl = _objectDeclarationPath(body, view, pool, at, recordRegionLength);
    if (decl == null || !_isSequenceDeclaration(decl.$1)) continue;
    sequenceDecls.add((at, decl.$1[1]));
    sink.claim(at, decl.$2, _tierSemantic);
    sink.byte(at, body[at], _OpSource.struct);
    sink.byte(at + 1, body[at + 1], _OpSource.struct);
    for (var q = at + _PropRecordField.zeroA.offset; q + _u32Bytes <= decl.$2; q += _u32Bytes) {
      final word = view.getUint32(q, Endian.little);
      if (word == 0) {
        sink.u32(q, 0, _OpSource.grammar);
      } else {
        sink.poolRef(q, word);
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
    if (group != null && record.typeName == SeqValueClass.objects.wire) {
      markers.add((record.offset, group));
    }
  }

  final typeNames = sharedTypeNames ?? _typeNamesFromBody(body, recordRegionLength, pool);
  final stepToken = pool.indexOf(_stepToken);
  final found = <(int, String, int)>[];
  int wordAt(int at) => view.getUint32(at, Endian.little);
  String? poolAt(int index) => index > 0 && index < pool.length && pool[index].isNotEmpty ? pool[index] : null;
  if (stepToken > 0) {
    for (var at = 0; at + (_stepNameWordGap + 2) * _u32Bytes <= recordRegionLength; at++) {
      if (wordAt(at) != stepToken) continue;
      final typeWord = wordAt(at + _u32Bytes);
      final kind = poolAt(typeWord);
      final name = poolAt(wordAt(at + _stepNameWordGap * _u32Bytes));
      final container = poolAt(wordAt(at + (_stepNameWordGap + 1) * _u32Bytes));
      if (name == null || container == null || kind == null) continue;
      if (!_stepContainerTokens.contains(container)) continue;
      if (!_looksLikeUniqueId(kind) && !_stepExpressionKinds.contains(kind)) continue;
      found.add((at, name, typeWord - 1));
    }
  }
  Set<int> indicesOf(String token) => {
    for (var i = 1; i < pool.length; i++)
      if (pool[i] == token) i,
  };
  final viPathIdx = indicesOf('VIPath');
  final modulePathIdx = indicesOf('ModulePath');
  final functionIdx = indicesOf('FunctionOrAttributeName');
  String? pairIn(int start, int end, Set<int> nameIdx) {
    if (nameIdx.isEmpty) return null;
    for (var at = start; at + 2 * _u32Bytes <= end; at++) {
      if (!nameIdx.contains(wordAt(at))) continue;
      final value = poolAt(wordAt(at + _u32Bytes));
      if (value != null) {
        sink.claim(at, at + 2 * _u32Bytes, _tierSemantic);
        sink.poolRef(at, wordAt(at));
        sink.poolRef(at + _u32Bytes, wordAt(at + _u32Bytes));
        return value;
      }
    }
    return null;
  }

  final tsParser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;

  final steps = <(int, BinaryStepRef)>[];
  for (var i = 0; i < found.length; i++) {
    final (at, name, typeIndex) = found[i];
    final spanEnd = i + 1 < found.length ? found[i + 1].$1 : recordRegionLength;
    final (fields: tsSubProps, end: tsEnd) = tsParser.parseStepTs(at + 4 * _u32Bytes);
    sink.claim(at, at + 4 * _u32Bytes, _tierSemantic);
    sink.poolRef(at, wordAt(at));
    final typeWord = wordAt(at + _u32Bytes);
    if (typeIndex >= 0 && typeIndex < typeNames.length) {
      sink.u32(at + _u32Bytes, typeWord, _OpSource.model);
    } else {
      sink.u32(at + _u32Bytes, typeWord, _OpSource.struct);
    }
    sink.poolRef(at + 2 * _u32Bytes, wordAt(at + 2 * _u32Bytes));
    sink.poolRef(at + 3 * _u32Bytes, wordAt(at + 3 * _u32Bytes));
    if (tsSubProps.isNotEmpty && tsEnd != null) {
      sink.claim(at + 4 * _u32Bytes, tsEnd, _tierSemantic);
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
      at,
      BinaryStepRef(
        name,
        typeName: typeIndex >= 0 && typeIndex < typeNames.length ? typeNames[typeIndex] : null,
        viPath: pairIn(at, spanEnd, viPathIdx),
        pythonModule: pairIn(at, spanEnd, modulePathIdx),
        pythonFunction: pairIn(at, spanEnd, functionIdx),
        tsSubProps: tsSubProps,
        dataSubProps: dataSubProps,
      ),
    ));
  }

  sequenceDecls.sort((a, b) => a.$1.compareTo(b.$1));
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
  int u32(int at) => view.getUint32(at, Endian.little);
  Set<int> indicesOf(String token) => {
    for (var i = 1; i < pool.length; i++)
      if (pool[i] == token) i,
  };
  final anchors = [
    for (final spec in _tailSubProps) (indicesOf(spec.name), indicesOf(spec.className.wire), spec),
  ];
  final sorted = [...sequenceDecls]..sort((a, b) => a.$1.compareTo(b.$1));
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
  for (var at = 0; at + 4 * _u32Bytes <= recordRegionLength; at++) {
    for (final (nameIdx, classIdx, spec) in anchors) {
      if (u32(at + _u32Bytes) != 0) continue;
      if (!classIdx.contains(u32(at + 2 * _u32Bytes))) continue;
      if (!nameIdx.contains(u32(at + 3 * _u32Bytes))) continue;
      final mAnchor = sink.mark();
      final parsed = parser.parseFieldAt(at);
      if (parsed == null) continue;
      final (field, fieldEnd) = parsed;
      final owner = ownerOf(at);
      final seen = seenPerOwner.putIfAbsent(owner, () => <String>{});
      if (!spec.accepts(field) || !seen.add(spec.name)) {
        sink.rollback(mAnchor);
        continue;
      }
      sink.claim(at, fieldEnd, _tierSemantic);
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
  _TailSubProp('RecordResults', SeqValueClass.boolean, (f) => f.name == 'RecordResults' && f.value != null),
  _TailSubProp('FailureAction', SeqValueClass.number, (f) => f.name == 'FailureAction' && f.value != null),
  _TailSubProp(
    'Requirements',
    SeqValueClass.object,
    (f) =>
        f.name == 'Requirements' &&
        f.valueClass == SeqValueClass.object &&
        f.children.any((c) => c.name == 'Links' && c.valueClass == SeqValueClass.strings),
  ),
  _TailSubProp(
    'RTS',
    SeqValueClass.object,
    (f) => f.name == 'RTS' && f.valueClass == SeqValueClass.object && f.children.isNotEmpty,
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
    for (var i = 1; i < pool.length; i++)
      if (sequenceNames.contains(pool[i])) i: pool[i],
  };
  if (nameIndices.isEmpty) return const {};
  int u32(int at) => view.getUint32(at, Endian.little);
  final result = <String, List<BinaryTypeField>>{};
  final parser = _TypeBodyParser(view, pool, recordRegionLength, table, null, typeIndexBase)..ops = sink;
  for (var at = 0; at + 3 * _u32Bytes <= recordRegionLength; at += 1) {
    if (u32(at) != sequenceToken) continue;
    final name = nameIndices[u32(at + _u32Bytes)];
    if (name == null || result.containsKey(name)) continue;
    final count = u32(at + 2 * _u32Bytes);
    if (count < 1 || count > _typeMaxFields) continue;
    final mWalk = sink.mark();
    final decoded = parser.parseLeadingSubProps(at + 3 * _u32Bytes, count, _stepGroupNames);
    final subProps = <BinaryTypeField>[];
    var keptEnd = at + 3 * _u32Bytes;
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
    sink.poolRef(at, u32(at));
    sink.poolRef(at + _u32Bytes, u32(at + _u32Bytes));
    sink.u32(at + 2 * _u32Bytes, count, _OpSource.model);
    sink.claim(at, keptEnd, _tierSemantic);
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
  for (var i = 0; i + _u32Bytes <= body.length && out.length < count; i += _u32Bytes) {
    out.add(view.getUint32(i, Endian.little));
  }
  return out;
}

int? _recordRegionBoundary(Uint8List body) {
  int? prevStart, prevLen;
  var chainStart = -1;
  var chainCount = 0;
  var runStart = -1;
  final n = body.length;
  for (var i = 0; i <= n; i++) {
    if (i < n && isBinaryPrintable(body[i])) {
      if (runStart < 0) runStart = i;
      continue;
    }
    if (runStart >= 0) {
      final len = i - runStart;
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
  for (var i = 0; i < runs.length; i++) {
    if (i > 0) {
      final prev = runs[i - 1];
      if (_packedAfter(prev, runs[i])) {
        len++;
        continue;
      }
      if (len >= chainMin) return chainStart;
    }
    chainStart = runs[i].offset;
    len = 1;
  }
  return len >= chainMin ? chainStart : null;
}

int _countSentinels(Uint8List bytes, int end) {
  final limit = end < bytes.length ? end : bytes.length;
  final view = ByteData.sublistView(bytes);
  var count = 0;
  for (var i = 0; i + _u32Bytes <= limit; i += _u32Bytes) {
    if (view.getUint32(i, Endian.little) == _sentinelWord) count++;
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
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
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
    for (var v = 0; v < _typeVersionTripleWords; v++) {
      final wordAt = headAt + tripleAt + v * _u32Bytes;
      sink.poolRef(wordAt, view.getUint32(wordAt, Endian.little));
    }
    final tailAt = headAt + tripleAt + _typeVersionTripleWords * _u32Bytes;
    if (bodyAt != null &&
        bodyAt >= _u32Bytes &&
        view.getUint32(bodyAt - _u32Bytes, Endian.little) == _recordDelimiter) {
      final flagsEnd = tailAt + record.flags.length * _u32Bytes;
      for (var q = tailAt; q + _u32Bytes <= headEnd; q += _u32Bytes) {
        final word = view.getUint32(q, Endian.little);
        if (q < flagsEnd) {
          sink.u32(q, word, _OpSource.model);
        } else if (word == 0 || word == _recordDelimiter) {
          sink.u32(q, word, _OpSource.grammar);
        } else {
          sink.u32(q, word, _OpSource.struct);
        }
      }
    } else if (bodyAt != null) {
      sink.u32(tailAt, 1, _OpSource.grammar);
      sink.poolRef(tailAt + _u32Bytes, view.getUint32(tailAt + _u32Bytes, Endian.little));
    }
    final nextHeadAt = i + 1 < records.length ? headOffsets[records[i + 1].name] : null;
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
