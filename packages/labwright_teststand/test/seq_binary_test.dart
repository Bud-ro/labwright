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
}
