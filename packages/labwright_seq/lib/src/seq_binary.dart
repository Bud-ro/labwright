import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'seq_file.dart';
import 'seq_format.dart';
import 'seq_property.dart';

part 'seq_binary_layout.dart';
part 'seq_binary_metrics.dart';
part 'seq_binary_outlines.dart';
part 'seq_binary_properties.dart';
part 'seq_binary_type_body.dart';
part 'seq_binary_type_records.dart';
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
