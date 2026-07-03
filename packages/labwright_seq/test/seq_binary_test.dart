import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Builds a fake TOF1 file: header + preamble + a zlib stream of [bodyBytes].
Uint8List _tof1(List<int> bodyBytes) {
  final b = BytesBuilder()
    ..add(ascii.encode('TOF1'))
    ..add(List.filled(6, 0))
    ..add(ascii.encode('SequenceFile'))
    ..add(List.filled(0x100, 0))
    ..add(zlib.encode(bodyBytes));
  return Uint8List.fromList(b.toBytes());
}

void main() {
  test('inflateBinaryBody locates + inflates the TOF1 zlib body', () {
    final body = inflateBinaryBody(_tof1(ascii.encode('SequenceFileData-MainSequence-Step' * 4)));
    expect(body, isNotNull);
    expect(ascii.decode(body!), contains('MainSequence'));
  });

  test('binaryBodyStrings recovers the NUL-terminated name pool', () {
    final pool = <int>[];
    for (final name in ['PaddingNameToExceedTheSixtyFourByteInflateGuardInThisTest',
        'SequenceFileData', 'MainSequence', 'Step', 'Locals']) {
      pool.addAll(ascii.encode(name));
      pool.add(0);
    }
    final names = binaryBodyStrings(_tof1(pool)).map((s) => s.text).toList();
    expect(names, containsAll(['SequenceFileData', 'MainSequence', 'Step', 'Locals']));
  });

  test('binaryStringTable isolates the contiguous NUL-packed name table', () {
    final body = <int>[];
    body.addAll([0xAA, 0xBB, 0xCC, 0x01, 0x00, 0x00, 0x00]);
    body.addAll(ascii.encode('xy'));
    body.add(0x00);
    body.addAll([0xFF, 0xFF, 0xFF, 0xFF]);
    body.add(0x00);
    for (final name in ['SequenceFileData', 'Data', 'Objs', 'Sequence',
        'MainSequence', 'Parameters', 'Locals', 'Step']) {
      body.addAll(ascii.encode(name));
      body.add(0);
    }
    final pool = binaryStringTable(_tof1(body)).map((s) => s.text).toList();
    expect(pool, containsAll(['SequenceFileData', 'Sequence', 'MainSequence', 'Step', 'Locals']));
    expect(pool, isNot(contains('xy')));
  });

  test('returns null/empty for non-binary / arbitrary input (no throw)', () {
    expect(inflateBinaryBody(Uint8List.fromList(ascii.encode('<?xml?>'))), isNull);
    expect(inflateBinaryBody(Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, 1, 2, 3])), isNull);
    expect(inflateBinaryBody(Uint8List(0)), isNull);
    expect(binaryBodyStrings(Uint8List(0)), isEmpty);
    expect(binaryStringTable(Uint8List(0)), isEmpty);
    expect(binaryModulePaths(Uint8List(0)), isEmpty);
    expect(binaryStepReferences(Uint8List(0)), isEmpty);
  });

  test('isBinaryModulePath recognises adapter call targets', () {
    expect(isBinaryModulePath(r'My Computer\ExcelReadWrite\Excel_Read.vi'), isTrue);
    expect(isBinaryModulePath(r'SubSequences\2-Gerilim\AC_Gerilim.seq'), isTrue);
    expect(isBinaryModulePath(r'lib\native\driver.DLL'), isTrue);
    expect(isBinaryModulePath(r'old\vis.llb'), isTrue);
    expect(isBinaryModulePath('.vi'), isFalse);
    expect(isBinaryModulePath('Status'), isFalse);
    expect(isBinaryModulePath('Excel_Read.vi'), isFalse);
    expect(isBinaryModulePath(r'notes\readme.txt'), isFalse);
  });

  test('isBinaryExpression recognises TestStand logic strings', () {
    expect(isBinaryExpression('Locals.Voltage == 5'), isTrue);
    expect(isBinaryExpression('RunState.LoopIndex += 1'), isTrue);
    expect(isBinaryExpression('Step.Result.Error.Occurred'), isTrue);
    expect(isBinaryExpression('Abs(Locals.FD1) <= 0.1'), isTrue);
    expect(isBinaryExpression(r'ResStr("NI_STEPTYPES", "ACTION_DEF_STEP_NAME")'),
        isTrue);
    expect(isBinaryExpression('(x == 0) ? "a" : "b"'), isTrue);
    expect(isBinaryExpression('Status'), isFalse);
    expect(isBinaryExpression('Measurement 0'), isFalse);
    expect(isBinaryExpression('ID#:abc.Step.x'), isFalse);
    expect(isBinaryExpression(r'My Computer\Excel\Read.vi'), isFalse);
  });

  test('binaryExpressions/binaryModulePaths empty on non-binary input', () {
    expect(binaryExpressions(Uint8List(0)), isEmpty);
    expect(binaryQuotedLiterals(Uint8List(0)), isEmpty);
  });

  test('isBinaryQuotedLiteral recognises constant value literals', () {
    expect(isBinaryQuotedLiteral('"6105A"'), isTrue);
    expect(isBinaryQuotedLiteral('"Unnamed Entry Point"'), isTrue);
    expect(isBinaryQuotedLiteral('""'), isTrue);
    expect(isBinaryQuotedLiteral('6105A'), isFalse);
    expect(isBinaryQuotedLiteral('"open'), isFalse);
    expect(isBinaryQuotedLiteral('"a" == "b"'), isFalse);
    expect(isBinaryExpression('"a" == "b"'), isTrue);
  });

  test('binaryScalarDoubles recovers clean inline IEEE-754 doubles', () {
    final bd = ByteData(8);
    List<int> f64le(double v) {
      bd.setFloat64(0, v, Endian.little);
      return [for (var i = 0; i < 8; i++) bd.getUint8(i)];
    }
    final rec = <int>[
      0x1c, 0x00, 0x00, 0x00,
      ...f64le(8192.0),
      ...f64le(1.0),
      ...f64le(3.14159265358979),
    ];
    final pool = <int>[];
    for (final name in ['SequenceFileData', 'MainSequence', 'StepGroupMain',
        'LocalsVarOne', 'ResultListItem', 'ParametersBlock']) {
      pool..addAll(ascii.encode(name))..add(0);
    }
    final got = binaryScalarDoubles(_tof1([...rec, ...pool]));
    expect(got, containsAll(<double>[8192.0, 1.0]));
    expect(got, isNot(contains(3.14159265358979)));
  });

  test('binaryScalarDoubles empty on non-binary input', () {
    expect(binaryScalarDoubles(Uint8List(0)), isEmpty);
  });

  test('binaryNamedScalarRecords pairs a named-property header with its f64', () {
    final bd = ByteData(8);
    List<int> f64le(double v) {
      bd.setFloat64(0, v, Endian.little);
      return [for (var i = 0; i < 8; i++) bd.getUint8(i)];
    }

    List<int> u32le(int v) =>
        [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];

    final pool = <int>[];
    final relOf = <String, int>{};
    for (final name in ['PadName', 'Parameters', 'Locals', 'ResultList',
        'StepEntry', 'SeqEntry']) {
      relOf[name] = pool.length;
      pool..addAll(ascii.encode(name))..add(0);
    }
    expect(relOf['Parameters'], 8);

    final rec = <int>[
      ...u32le(0),
      ...u32le(0),
      ...u32le(relOf['Parameters']!),
      ...u32le(99),
      ...f64le(42.0),
      ...u32le(0),
      ...u32le(0),
      ...u32le(0),
      ...u32le(0),
      ...u32le(0),
      ...u32le(0),
    ];
    expect(rec.length, 48);

    final recs = binaryNamedScalarRecords(_tof1([...rec, ...pool]));
    expect(recs, hasLength(1));
    final r = recs.single;
    expect(r.name, 'Parameters');
    expect(r.rawTag, 0);
    expect(r.rawTypeCode, 99);
    expect(r.value, 42.0);
  });

  test('binaryNamedScalarRecords empty on non-binary input', () {
    expect(binaryNamedScalarRecords(Uint8List(0)), isEmpty);
    expect(binaryNamedScalarRecords(
        Uint8List.fromList(ascii.encode('<?xml?>'))), isEmpty);
  });

  test('dumpBinaryRecon reports recovered data + honest not-yet-decoded note', () {
    final bd = ByteData(8);
    List<int> f64le(double v) {
      bd.setFloat64(0, v, Endian.little);
      return [for (var i = 0; i < 8; i++) bd.getUint8(i)];
    }
    List<int> u32le(int v) =>
        [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];

    final pool = <int>[];
    for (final name in ['PadName', 'Parameters', 'Locals', 'ResultList',
        'StepEntry', 'SeqEntry']) {
      pool..addAll(ascii.encode(name))..add(0);
    }
    final rec = <int>[
      ...u32le(0), ...u32le(0), ...u32le(8), ...u32le(99),
      ...f64le(42.0),
      ...u32le(0), ...u32le(0), ...u32le(0), ...u32le(0), ...u32le(0),
      ...u32le(0),
    ];

    final text = dumpBinaryRecon(_tof1([...rec, ...pool]));
    expect(text, contains('=== Layout ==='));
    expect(text, contains('=== Named scalar values (1) ==='));
    expect(text, contains('Parameters = 42.0  (raw type 99, not modeled)'));
    expect(text, contains('record links not yet decoded'));

    expect(dumpBinaryRecon(Uint8List.fromList(ascii.encode('<?xml?>'))),
        '(not a binary TOF1 file)');
  });

  test('binaryNamedRecords keeps consistently-tagged names, drops the rest', () {
    List<int> u32le(int v) =>
        [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];

    final pool = <int>[];
    for (final name in ['PadName', 'Parameters', 'Locals', 'ResultList',
        'StepX', 'SeqX']) {
      pool..addAll(ascii.encode(name))..add(0);
    }

    final rec = <int>[
      ...u32le(0), ...u32le(5), ...u32le(8), ...u32le(0),
      ...u32le(5), ...u32le(8), ...u32le(0), ...u32le(3),
      ...u32le(19), ...u32le(0), ...u32le(4), ...u32le(19),
      ...u32le(0), ...u32le(0), ...u32le(0), ...u32le(0),
    ];

    final recs = binaryNamedRecords(_tof1([...rec, ...pool]));
    expect(recs, hasLength(1));
    expect(recs.single.name, 'Parameters');
    expect(recs.single.count, 2);
    expect(recs.single.rawTag, 5);
    expect(recs.map((r) => r.name), isNot(contains('Locals')));
  });

  test('binaryNamedRecords empty on non-binary input', () {
    expect(binaryNamedRecords(Uint8List(0)), isEmpty);
  });
}
