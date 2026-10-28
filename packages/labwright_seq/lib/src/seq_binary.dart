/// `TOF1` binary sequence files: container inflation, the decoded body, and the recon lenses that still
/// apply when a body does not follow the record grammar.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'seq_binary_grammar.dart';
import 'seq_binary_header.dart';
import 'seq_binary_model.dart';
import 'seq_file.dart';
import 'seq_format.dart';

const _zlibCmf = 0x78;

/// Second byte of a zlib stream header, by compression level.
enum ZlibFlag {
  none(0x01),

  byDefault(0x9c),

  best(0xda);

  const ZlibFlag(this.byte);
  final int byte;

  static bool isKnown(int flagByte) => flagByte == none.byte || flagByte == byDefault.byte || flagByte == best.byte;
}

const _minInflatedBytes = 64;

const _maxInflatedBytes = 128 * 1024 * 1024;

/// Inflates the body of a `TOF1` file; null when the bytes are not such a file or the body does not inflate.
Uint8List? inflateBinaryBody(Uint8List bytes) => locateAndInflateBody(bytes)?.$2;

/// The zlib stream offset and the inflated body.
///
/// A header carrying the `PMCZ` marker fixes the stream at [Tof1HeaderField.body]; otherwise the first
/// inflatable zlib header after the magic is used.
(int, Uint8List)? locateAndInflateBody(Uint8List bytes) {
  if (detectSeqFormat(bytes) != SeqFormat.binary) return null;
  final header = Tof1Header.parse(bytes);
  if (header != null && header.hasBodyMarker) {
    final out = _inflateCapped(Uint8List.sublistView(bytes, Tof1HeaderField.body.offset));
    if (out != null) return (Tof1HeaderField.body.offset, out);
    return null;
  }
  for (var i = Tof1HeaderField.magic.end; i + 1 < bytes.length; i++) {
    if (bytes[i] != _zlibCmf || !ZlibFlag.isKnown(bytes[i + 1])) continue;
    final out = _inflateCapped(Uint8List.sublistView(bytes, i));
    if (out != null && out.length > _minInflatedBytes) return (i, out);
  }
  return null;
}

Uint8List? _inflateCapped(Uint8List input) {
  final sink = _CappedByteSink(_maxInflatedBytes);
  try {
    final decoderInput = ZLibDecoder().startChunkedConversion(sink);
    const chunk = 1 << 16;
    for (var o = 0; o < input.length && !sink.overflowed; o += chunk) {
      final end = o + chunk < input.length ? o + chunk : input.length;
      decoderInput.add(Uint8List.sublistView(input, o, end));
    }
    if (!sink.overflowed) decoderInput.close();
  } catch (_) {
    return null;
  }
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

/// A `TOF1` file taken apart: header, inflated body and, when the body follows the grammar, its decoding.
final class Tof1Decode {
  const Tof1Decode({required this.header, required this.body, this.grammar, this.error});

  final Tof1Header? header;

  final Uint8List body;

  final Tof1Body? grammar;

  /// Why the grammar did not apply, when [grammar] is null.
  final String? error;
}

/// Inflates and decodes [bytes]; null when the body does not inflate.
Tof1Decode? decodeTof1(Uint8List bytes, {Uint8List? body}) {
  final inflated = body ?? inflateBinaryBody(bytes);
  if (inflated == null) return null;
  final header = Tof1Header.parse(bytes);
  if (header == null || !header.hasBodyMarker) {
    return Tof1Decode(header: header, body: inflated, error: 'header lacks the PMCZ body marker');
  }
  try {
    final grammar = parseTof1Body(
      inflated,
      recordRegionLength: header.recordRegionLength,
      generation: header.generation,
    );
    return Tof1Decode(header: header, body: inflated, grammar: grammar);
  } on FormatException catch (e) {
    return Tof1Decode(header: header, body: inflated, error: e.toString());
  }
}

/// Printable runs of the inflated body, by offset.
List<BinaryString> binaryBodyStrings(Uint8List seqBytes, {int minLength = 2}) {
  final body = inflateBinaryBody(seqBytes);
  if (body == null) return const [];
  return binaryStrings(body, minLength: minLength);
}

final _modulePathRe = RegExp(r'\.(vi|dll|seq|llb)$', caseSensitive: false);

bool isBinaryModulePath(String text) => text.contains('\\') && _modulePathRe.hasMatch(text);

bool _isStepRef(String text) => text.startsWith('ID#:');

final _exprRootRe = RegExp(r'\b(Locals|Parameters|Step|RunState|FileGlobals|StationGlobals|Seq|ThisContext)\.');

final _exprOpRe = RegExp(r'(==|!=|<=|>=|&&|\|\||\?.*:)');

final _exprFnRe = RegExp(r'\b(Abs|Str|Val|Round|Mid|Len|Left|Right|ResStr|LocalizeExpression|Mod)\s*\(');

bool isBinaryExpression(String text) {
  if (_isStepRef(text) || isBinaryModulePath(text)) return false;
  return _exprRootRe.hasMatch(text) || _exprOpRe.hasMatch(text) || _exprFnRe.hasMatch(text);
}

bool isBinaryQuotedLiteral(String text) =>
    text.length >= 2 && text.startsWith('"') && text.endsWith('"') && !isBinaryExpression(text);

List<String> _where(Iterable<String> texts, bool Function(String) keep) {
  final seen = <String>{};
  return [
    for (final text in texts)
      if (keep(text) && seen.add(text)) text,
  ];
}

/// Framing of the inflated body: the record region and the string region after it.
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

  /// `0xffffffff` words inside the record region: null strings, inherited class slots and the terminator.
  final int sentinelCount;

  final int segmentCount;

  /// The first body word: the type count when the grammar applies.
  final List<int> leadingWords;

  @override
  String toString() =>
      'BinaryBodyLayout(inflated=$inflatedSize, '
      'recordRegion=$recordRegionLength, strings=$stringCount, '
      'segments=$segmentCount, sentinels=$sentinelCount, lead=$leadingWords)';
}

/// A `Num` recovered by the recon scan of a body outside the grammar: a name index, a tag, a type word and a double.
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

/// A name referenced repeatedly with one consistent preceding word, from the recon scan.
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

/// What can be said about a binary body: the grammar's decoding when it applies, the recon lenses otherwise.
class BinaryAnalysis {
  const BinaryAnalysis({
    required this.inflatedSize,
    required this.strings,
    required this.stringTable,
    required this.layout,
    required this.nameTable,
    required this.objectNames,
    required this.modulePaths,
    required this.stepReferences,
    required this.expressions,
    required this.quotedLiterals,
    required this.namedScalars,
    required this.scalarDoubles,
    required this.namedRecords,
    this.decode,
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

  final Tof1Decode? decode;

  bool get grammarApplies => decode?.grammar != null;
}

BinaryAnalysis? analyzeBinary(Uint8List seqBytes, {Uint8List? body}) {
  final decode = decodeTof1(seqBytes, body: body);
  if (decode == null) return null;
  final grammar = decode.grammar;
  if (grammar != null) return _analysisFromGrammar(decode, grammar);
  return _reconAnalysis(decode);
}

BinaryAnalysis _analysisFromGrammar(Tof1Decode decode, Tof1Body grammar) {
  final pool = [
    for (var i = 0; i < grammar.pool.length; i++) (offset: grammar.poolOffsets[i], text: grammar.pool[i]),
  ];
  final objectNames = <String>[];
  try {
    final file = tof1BodyToSeqFile(grammar, decode.header!);
    for (final sequence in file.sequences) {
      objectNames.add(sequence.name);
      for (final step in sequence.steps) {
        objectNames.add(step.name);
      }
    }
  } on FormatException {
    objectNames.clear();
  }
  return BinaryAnalysis(
    inflatedSize: grammar.bytes.length,
    strings: pool,
    stringTable: pool,
    layout: BinaryBodyLayout(
      inflatedSize: grammar.bytes.length,
      recordRegionLength: grammar.recordRegionLength,
      stringCount: grammar.pool.length,
      sentinelCount: _countSentinels(grammar.bytes, grammar.recordRegionLength),
      segmentCount: 1,
      leadingWords: [grammar.types.length],
    ),
    nameTable: pool,
    objectNames: objectNames,
    modulePaths: _where(grammar.pool, isBinaryModulePath),
    stepReferences: _where(grammar.pool, _isStepRef),
    expressions: _where(grammar.pool, isBinaryExpression),
    quotedLiterals: _where(grammar.pool, isBinaryQuotedLiteral),
    namedScalars: const [],
    scalarDoubles: const [],
    namedRecords: const [],
    decode: decode,
  );
}

int _countSentinels(Uint8List body, int end) {
  final view = ByteData.sublistView(body);
  var count = 0;
  for (var i = 0; i + 4 <= end; i += 4) {
    if (view.getUint32(i, Endian.little) == binaryNullIndex) count++;
  }
  return count;
}

const _minRunLength = 3;

const _boundaryChainMin = 5;

const _modelNameTokens = {
  'Sequence',
  'MainSequence',
  'SequenceFile',
  'Step',
  'StepType',
  'Locals',
  'Parameters',
};

/// The leading pool entries of every grammar-conforming body.
const binaryNameScaffold = ['SequenceFileData', 'Data', 'Objs', 'Seq', '[0]'];

/// Recon lenses for a body the grammar does not decode: NUL-packed string chains and the words around names.
BinaryAnalysis _reconAnalysis(Tof1Decode decode) {
  final body = decode.body;
  final runs = binaryStrings(body, minLength: _minRunLength);
  final chains = _chains(runs);
  int? boundary;
  for (final chain in chains) {
    if (chain.length >= _boundaryChainMin) {
      boundary = chain.first.offset;
      break;
    }
  }
  var table = const <BinaryString>[];
  for (final chain in chains) {
    if (chain.length > table.length) table = chain;
  }
  var nameTable = const <BinaryString>[];
  var bestHits = 0;
  for (final chain in chains) {
    final texts = {for (final entry in chain) entry.text};
    final hits = _modelNameTokens.where(texts.contains).length;
    if (hits > bestHits) {
      bestHits = hits;
      nameTable = chain;
    }
  }
  final texts = [for (final run in runs) run.text];
  final recordRegionLength = boundary ?? body.length;
  return BinaryAnalysis(
    inflatedSize: body.length,
    strings: runs,
    stringTable: table,
    layout: boundary == null
        ? null
        : BinaryBodyLayout(
            inflatedSize: body.length,
            recordRegionLength: boundary,
            stringCount: runs.where((r) => r.offset >= boundary!).length,
            sentinelCount: _countSentinels(body, boundary),
            segmentCount: chains.where((c) => c.length >= 2 && c.first.offset >= boundary!).length,
            leadingWords: _leadingWords(body, 3),
          ),
    nameTable: nameTable,
    objectNames: _objectNamesFrom([for (final entry in nameTable) entry.text]),
    modulePaths: _where(texts, isBinaryModulePath),
    stepReferences: _where(texts, _isStepRef),
    expressions: _where(texts, isBinaryExpression),
    quotedLiterals: _where(texts, isBinaryQuotedLiteral),
    namedScalars: _namedScalars(body, recordRegionLength, runs),
    scalarDoubles: _scalarDoubles(body, recordRegionLength),
    namedRecords: _namedRecords(body, recordRegionLength, runs),
    decode: decode,
  );
}

List<List<BinaryString>> _chains(List<BinaryString> runs) {
  final chains = <List<BinaryString>>[];
  List<BinaryString>? current;
  BinaryString? previous;
  for (final run in runs) {
    if (previous != null && run.offset == previous.offset + previous.text.length + 1) {
      current!.add(run);
    } else {
      current = [run];
      chains.add(current);
    }
    previous = run;
  }
  return chains;
}

List<int> _leadingWords(Uint8List body, int count) {
  final view = ByteData.sublistView(body);
  return [
    for (var i = 0; i < count && (i + 1) * 4 <= body.length; i++) view.getUint32(i * 4, Endian.little),
  ];
}

List<String> _objectNamesFrom(List<String> names) {
  var start = 0;
  while (start < names.length && start < binaryNameScaffold.length && names[start] == binaryNameScaffold[start]) {
    start++;
  }
  return names.sublist(start);
}

const _minScalarMagnitude = 1e-9;

const _maxScalarMagnitude = 1e12;

bool _isCleanScalar(double value) {
  if (!value.isFinite || value == 0) return false;
  final magnitude = value.abs();
  return magnitude >= _minScalarMagnitude && magnitude <= _maxScalarMagnitude;
}

List<double> _scalarDoubles(Uint8List body, int recordRegionLength) {
  final view = ByteData.sublistView(body);
  final seen = <double>{};
  final out = <double>[];
  for (var i = 0; i + 8 <= recordRegionLength; i += 4) {
    if (view.getUint32(i, Endian.little) != 0) continue;
    final value = view.getFloat64(i, Endian.little);
    if (_isCleanScalar(value) && seen.add(value)) out.add(value);
  }
  return out;
}

Map<int, String> _namesByRelativeOffset(List<BinaryString> runs, int recordRegionLength) => {
  for (final run in runs)
    if (run.offset >= recordRegionLength) run.offset - recordRegionLength: run.text,
};

List<BinaryNamedScalar> _namedScalars(Uint8List body, int recordRegionLength, List<BinaryString> runs) {
  final relToName = _namesByRelativeOffset(runs, recordRegionLength);
  if (relToName.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final out = <BinaryNamedScalar>[];
  final wordCount = recordRegionLength ~/ 4;
  for (var wordIndex = 1; wordIndex + 3 < wordCount; wordIndex++) {
    final name = relToName[view.getUint32(wordIndex * 4, Endian.little)];
    if (name == null) continue;
    final doubleOffset = (wordIndex + 2) * 4;
    if (doubleOffset + 8 > recordRegionLength || view.getUint32(doubleOffset, Endian.little) != 0) continue;
    final value = view.getFloat64(doubleOffset, Endian.little);
    if (!_isCleanScalar(value)) continue;
    out.add(
      BinaryNamedScalar(
        name: name,
        rawTag: view.getUint32((wordIndex - 1) * 4, Endian.little),
        rawTypeCode: view.getUint32((wordIndex + 1) * 4, Endian.little),
        value: value,
        wordIndex: wordIndex,
      ),
    );
  }
  return out;
}

bool _isNameLike(String text) =>
    !isBinaryQuotedLiteral(text) && !isBinaryExpression(text) && !isBinaryModulePath(text) && !_isStepRef(text);

List<BinaryNamedRecord> _namedRecords(Uint8List body, int recordRegionLength, List<BinaryString> runs) {
  final relToName = _namesByRelativeOffset(runs, recordRegionLength);
  if (relToName.isEmpty) return const [];
  final view = ByteData.sublistView(body);
  final counts = <String, int>{};
  final tags = <String, Set<int>>{};
  final wordCount = recordRegionLength ~/ 4;
  for (var wordIndex = 1; wordIndex + 1 < wordCount; wordIndex++) {
    final off = view.getUint32(wordIndex * 4, Endian.little);
    if (off == 0) continue;
    final name = relToName[off];
    if (name == null || name.isEmpty || !_isNameLike(name)) continue;
    counts.update(name, (v) => v + 1, ifAbsent: () => 1);
    (tags[name] ??= <int>{}).add(view.getUint32((wordIndex - 1) * 4, Endian.little));
  }
  final out = <BinaryNamedRecord>[
    for (final entry in counts.entries)
      if (entry.value >= 2 && tags[entry.key]!.length == 1)
        BinaryNamedRecord(name: entry.key, count: entry.value, rawTag: tags[entry.key]!.single),
  ];
  out.sort((a, b) => b.count.compareTo(a.count));
  return out;
}

/// Sequence names of a binary file, in file order; empty when the body does not decode.
List<String> binarySequenceNames(Uint8List seqBytes) {
  final SeqFile file;
  try {
    file = parseBinarySeqFile(seqBytes);
  } on FormatException {
    return const [];
  }
  return [for (final sequence in file.sequences) sequence.name];
}
