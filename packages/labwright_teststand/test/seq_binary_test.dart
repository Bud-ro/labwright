import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

/// Builds a fake TOF1 file: header + preamble + a zlib stream of [bodyBytes].
Uint8List _tof1(List<int> bodyBytes) {
  final b = BytesBuilder()
    ..add(ascii.encode('TOF1'))
    ..add(List.filled(6, 0))
    ..add(ascii.encode('SequenceFile'))
    ..add(List.filled(0x100, 0)) // header/preamble padding
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
    // Padding name first so the inflated body exceeds the >64-byte guard.
    for (final name in ['PaddingNameToExceedTheSixtyFourByteInflateGuardInThisTest',
        'SequenceFileData', 'MainSequence', 'Step', 'Locals']) {
      pool.addAll(ascii.encode(name));
      pool.add(0); // NUL terminator between names, as the real body stores them
    }
    final names = binaryBodyStrings(_tof1(pool)).map((s) => s.text).toList();
    expect(names, containsAll(['SequenceFileData', 'MainSequence', 'Step', 'Locals']));
  });

  test('binaryStringTable isolates the contiguous NUL-packed name table', () {
    final body = <int>[];
    // Record-region noise first (short isolated ASCII + binary), then the pool.
    body.addAll([0xAA, 0xBB, 0xCC, 0x01, 0x00, 0x00, 0x00]);
    body.addAll(ascii.encode('xy')); // 2-char noise, below the pool minLength
    body.add(0x00);
    body.addAll([0xFF, 0xFF, 0xFF, 0xFF]);
    body.add(0x00); // sentinel NUL-separated from the pool (as in real files)
    for (final name in ['SequenceFileData', 'Data', 'Objs', 'Sequence',
        'MainSequence', 'Parameters', 'Locals', 'Step']) {
      body.addAll(ascii.encode(name));
      body.add(0);
    }
    final pool = binaryStringTable(_tof1(body)).map((s) => s.text).toList();
    expect(pool, containsAll(['SequenceFileData', 'Sequence', 'MainSequence', 'Step', 'Locals']));
    expect(pool, isNot(contains('xy'))); // record-region noise excluded
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
    // Positives: path-separated, known adapter extension.
    expect(isBinaryModulePath(r'My Computer\ExcelReadWrite\Excel_Read.vi'), isTrue);
    expect(isBinaryModulePath(r'SubSequences\2-Gerilim\AC_Gerilim.seq'), isTrue);
    expect(isBinaryModulePath(r'lib\native\driver.DLL'), isTrue); // case-insensitive
    expect(isBinaryModulePath(r'old\vis.llb'), isTrue);
    // Negatives: bare suffix, no separator, plain token, wrong extension.
    expect(isBinaryModulePath('.vi'), isFalse);
    expect(isBinaryModulePath('Status'), isFalse);
    expect(isBinaryModulePath('Excel_Read.vi'), isFalse); // no separator
    expect(isBinaryModulePath(r'notes\readme.txt'), isFalse);
  });

  test('isBinaryExpression recognises TestStand logic strings', () {
    // Positives: root member access, operators, ternary, known functions.
    expect(isBinaryExpression('Locals.Voltage == 5'), isTrue);
    expect(isBinaryExpression('RunState.LoopIndex += 1'), isTrue);
    expect(isBinaryExpression('Step.Result.Error.Occurred'), isTrue);
    expect(isBinaryExpression('Abs(Locals.FD1) <= 0.1'), isTrue);
    expect(isBinaryExpression(r'ResStr("NI_STEPTYPES", "ACTION_DEF_STEP_NAME")'),
        isTrue);
    expect(isBinaryExpression('(x == 0) ? "a" : "b"'), isTrue);
    // Negatives: plain names, literals, step refs, module paths.
    expect(isBinaryExpression('Status'), isFalse);
    expect(isBinaryExpression('Measurement 0'), isFalse);
    expect(isBinaryExpression('ID#:abc.Step.x'), isFalse); // ID# excluded first
    expect(isBinaryExpression(r'My Computer\Excel\Read.vi'), isFalse);
  });

  test('binaryExpressions/binaryModulePaths empty on non-binary input', () {
    expect(binaryExpressions(Uint8List(0)), isEmpty);
    expect(binaryQuotedLiterals(Uint8List(0)), isEmpty);
  });

  test('isBinaryQuotedLiteral recognises constant value literals', () {
    // Positives: whole-entry quoted constants.
    expect(isBinaryQuotedLiteral('"6105A"'), isTrue);
    expect(isBinaryQuotedLiteral('"Unnamed Entry Point"'), isTrue);
    expect(isBinaryQuotedLiteral('""'), isTrue); // empty string literal
    // Negatives: unquoted, half-quoted, and quoted-but-actually-expressions.
    expect(isBinaryQuotedLiteral('6105A'), isFalse);
    expect(isBinaryQuotedLiteral('"open'), isFalse);
    expect(isBinaryQuotedLiteral('"a" == "b"'), isFalse); // expression, not literal
    // Disjoint from the expression recovery.
    expect(isBinaryExpression('"a" == "b"'), isTrue);
  });

  test('binaryScalarDoubles recovers clean inline IEEE-754 doubles', () {
    // Record region: a marker word, then three little-endian f64s — two "clean"
    // (low 32 bits zero: 8192.0 and 1.0) and one whose low word is non-zero
    // (3.14159...) which must be rejected as not-a-round-default. Then a
    // NUL-packed name pool to frame the record/string boundary.
    final bd = ByteData(8);
    List<int> f64le(double v) {
      bd.setFloat64(0, v, Endian.little);
      return [for (var i = 0; i < 8; i++) bd.getUint8(i)];
    }
    final rec = <int>[
      0x1c, 0x00, 0x00, 0x00, // a leading marker word (non-double)
      ...f64le(8192.0), // clean: low word 0
      ...f64le(1.0), // clean: low word 0
      ...f64le(3.14159265358979), // dirty: low word non-zero -> rejected
    ];
    final pool = <int>[];
    for (final name in ['SequenceFileData', 'MainSequence', 'StepGroupMain',
        'LocalsVarOne', 'ResultListItem', 'ParametersBlock']) {
      pool..addAll(ascii.encode(name))..add(0);
    }
    final got = binaryScalarDoubles(_tof1([...rec, ...pool]));
    expect(got, containsAll(<double>[8192.0, 1.0]));
    expect(got, isNot(contains(3.14159265358979))); // low-word-0 filter rejects it
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

    // String region (record region length R == its start). A padding name first
    // so "Parameters" lands at a non-zero string-region-relative offset (8), the
    // value its name-offset word must carry.
    final pool = <int>[];
    final relOf = <String, int>{};
    for (final name in ['PadName', 'Parameters', 'Locals', 'ResultList',
        'StepEntry', 'SeqEntry']) {
      relOf[name] = pool.length; // rel offset within the string region
      pool..addAll(ascii.encode(name))..add(0);
    }
    expect(relOf['Parameters'], 8);

    // Record region: ⟨tag=0⟩⟨name-offset=8⟩⟨type=99⟩⟨f64 42.0⟩ then zero filler.
    // 12 words → R = 48 bytes, so the pool (and rr) begin at byte 48 and the
    // name-offset 8 resolves to (48+8)-48 = rel 8 = "Parameters". Zero-word filler
    // (not 0xFF) so the record region forms no printable run that would drag the
    // record/string boundary, and zero words can't pass the clean-f64 gate (0.0 is
    // rejected) so they emit no spurious records.
    final rec = <int>[
      ...u32le(0), // [0]
      ...u32le(0), // [1] tag
      ...u32le(relOf['Parameters']!), // [2] name-offset -> Parameters
      ...u32le(99), // [3] raw type code (not modeled)
      ...f64le(42.0), // [4..5] inline double
      ...u32le(0), // [6]
      ...u32le(0), // [7]
      ...u32le(0), // [8]
      ...u32le(0), // [9]
      ...u32le(0), // [10]
      ...u32le(0), // [11]
    ];
    expect(rec.length, 48); // R == pool start == recordRegionLength

    final recs = binaryNamedScalarRecords(_tof1([...rec, ...pool]));
    expect(recs, hasLength(1));
    final r = recs.single;
    expect(r.name, 'Parameters');
    expect(r.rawTag, 0);
    expect(r.rawTypeCode, 99); // carried verbatim, not interpreted
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

    // A Parameters-headed scalar record (rel 8) + a NUL-packed pool (see the
    // binaryNamedScalarRecords test for the framing rationale).
    final pool = <int>[];
    for (final name in ['PadName', 'Parameters', 'Locals', 'ResultList',
        'StepEntry', 'SeqEntry']) {
      pool..addAll(ascii.encode(name))..add(0);
    }
    final rec = <int>[
      ...u32le(0), ...u32le(0), ...u32le(8), ...u32le(99), // tag,name,type
      ...f64le(42.0),
      ...u32le(0), ...u32le(0), ...u32le(0), ...u32le(0), ...u32le(0),
      ...u32le(0),
    ];

    final text = dumpBinaryRecon(_tof1([...rec, ...pool]));
    expect(text, contains('=== Layout ==='));
    expect(text, contains('=== Named scalar values (1) ==='));
    expect(text, contains('Parameters = 42.0  (raw type 99, not modeled)'));
    // Honest about the still-undecoded record links.
    expect(text, contains('record links not yet decoded'));

    // Non-binary input is handled without throwing.
    expect(dumpBinaryRecon(Uint8List.fromList(ascii.encode('<?xml?>'))),
        '(not a binary TOF1 file)');
  });

  test('binaryNamedRecords keeps consistently-tagged names, drops the rest', () {
    List<int> u32le(int v) =>
        [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];

    // Pool: "Parameters" at rel 8, "Locals" at rel 19 (PadName at rel 0 is
    // excluded by the non-zero-offset rule).
    final pool = <int>[];
    for (final name in ['PadName', 'Parameters', 'Locals', 'ResultList',
        'StepX', 'SeqX']) {
      pool..addAll(ascii.encode(name))..add(0);
    }

    // 16 words → record region = 64 bytes, so the pool/rr begin at 64 and a
    // name-offset of 8 resolves to rel 8 = "Parameters".
    // Parameters (rel 8) referenced twice with the SAME tag 5 -> qualifies.
    // Locals (rel 19) referenced twice with DIFFERENT tags 3,4 -> dropped.
    final rec = <int>[
      ...u32le(0), ...u32le(5), ...u32le(8), ...u32le(0), // [2] Parameters tag5
      ...u32le(5), ...u32le(8), ...u32le(0), ...u32le(3), // [5] Parameters tag5
      ...u32le(19), ...u32le(0), ...u32le(4), ...u32le(19), // Locals tag3 / tag4
      ...u32le(0), ...u32le(0), ...u32le(0), ...u32le(0),
    ];

    final recs = binaryNamedRecords(_tof1([...rec, ...pool]));
    expect(recs, hasLength(1));
    expect(recs.single.name, 'Parameters');
    expect(recs.single.count, 2);
    expect(recs.single.rawTag, 5); // consistent tag, carried verbatim
    // Locals had two different preceding tags -> not a consistent header.
    expect(recs.map((r) => r.name), isNot(contains('Locals')));
  });

  test('binaryNamedRecords empty on non-binary input', () {
    expect(binaryNamedRecords(Uint8List(0)), isEmpty);
  });
}
