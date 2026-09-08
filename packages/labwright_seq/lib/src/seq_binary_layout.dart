part of 'seq_binary.dart';

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
