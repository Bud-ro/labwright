import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Builds a `TOF1` body byte by byte, interning strings into the pool as it goes.
class _BodyBuilder {
  final BytesBuilder _bytes = BytesBuilder();
  final List<String> pool = [];

  int get length => _bytes.length;

  int s(String text) {
    final index = pool.indexOf(text);
    if (index >= 0) return index;
    pool.add(text);
    return pool.length - 1;
  }

  void u32(int v) => _bytes.add([v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff]);

  void u8(int v) => _bytes.addByte(v);

  void f64(double v) => _bytes.add((ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List());

  void str(String? text) => u32(text == null ? binaryNullIndex : s(text));

  void leaf(String cls, String name, {Object? value, int flags = 0}) {
    final hasValue = value != null;
    u32(flags | (hasValue ? BinaryPropertyFlag.value.bit : 0));
    u32(0);
    str(cls);
    str(name);
    switch (value) {
      case null:
        break;
      case final double v:
        f64(v);
      case final bool v:
        u8(v ? 1 : 0);
      case final String v:
        str(v);
    }
    if (BinaryPropertyFlag.comment.isSetIn(flags)) str('a comment');
    if (BinaryPropertyFlag.numericFormat.isSetIn(flags)) str('%.2f');
    if (BinaryPropertyFlag.extData.isSetIn(flags)) {
      u32(1);
      str('CLUST');
      u8(1);
      u8(0);
      str('label');
    }
    u32(0);
  }

  void nums(String name, List<double> values) {
    u32(BinaryPropertyFlag.value.bit);
    u32(0);
    str('Nums');
    str(name);
    str('[0]');
    str('[${values.length - 1}]');
    for (final v in values) {
      f64(v);
    }
    u32(0);
  }

  Uint8List finish({bool terminateLast = true, List<int> tail = const []}) {
    u32(0);
    u32(binaryNullIndex);
    final recordRegionLength = _bytes.length;
    u32(pool.length);
    for (var i = 0; i < pool.length; i++) {
      _bytes.add(encodeWindows1252(pool[i])!);
      if (i < pool.length - 1 || terminateLast) _bytes.addByte(0);
    }
    _bytes.add(tail);
    return _file(_bytes.toBytes(), recordRegionLength);
  }

  static Uint8List _file(Uint8List body, int recordRegionLength, {int fileVersion = 962}) {
    final header = Uint8List(Tof1HeaderField.body.offset);
    header.setAll(0, ascii.encode('TOF1'));
    header.setAll(Tof1HeaderField.fileType.offset, ascii.encode('SequenceFile'));
    header.setAll(Tof1HeaderField.productName.offset, ascii.encode('TestStand'));
    header.setAll(Tof1HeaderField.productVersion.offset, ascii.encode('2021 SP1 (21.1.0.49154)'));
    header.setAll(Tof1HeaderField.bodyMarker.offset, ascii.encode('PMCZ'));
    final view = ByteData.sublistView(header);
    view.setUint32(Tof1HeaderField.fileVersion.offset, fileVersion, Endian.little);
    view.setUint32(Tof1HeaderField.recordRegionLength.offset, recordRegionLength, Endian.little);
    view.setUint32(Tof1HeaderField.inflatedLength.offset, body.length, Endian.little);
    return Uint8List.fromList([...header, ...zlib.encode(body)]);
  }
}

/// One typedef (a `Str` named `Expression`-like leaf and an `Obj` step type) and a data root with one
/// sequence holding one step and one local.
Uint8List _synthetic({bool terminateLast = true, List<int> tail = const []}) {
  final b = _BodyBuilder();
  for (final name in ['SequenceFileData', 'Data', 'Objs', 'Seq', '[0]', 'Sequence', 'MainSequence', 'Obj']) {
    b.s(name);
  }
  b.u32(2);
  // typedef 0: Expression (ExprValue leaf)
  b.u32(BinaryPropertyFlag.typeFlags.bit);
  b.u32(1);
  b.str('ExprValue');
  b.str('Expression');
  b.u32(3);
  b.u32(1650060499);
  b.u32(0);
  b.str('21.0.0.49156');
  b.str('21.1.0.49154');
  b.str('21.0.0.0');
  b.u32(33554436);
  b.u32(0);
  b.u32(binaryNullIndex);
  b.u32(0);
  b.u32(0);
  b.u32(0);
  b.u8(0);
  b.u32(1);
  // typedef 1: MyStep (StepType) with a TS container holding Icon and a typed PreCond
  b.u32(BinaryPropertyFlag.typeFlags.bit | BinaryPropertyFlag.valueFlags.bit);
  b.u32(1);
  b.str('StepType');
  b.str('MyStep');
  b.u32(1);
  b.u32(1650060499);
  b.u32(0);
  b.str('21.0.0.49156');
  b.str('21.1.0.49154');
  b.str('21.0.0.0');
  b.u32(33554438);
  b.u32(24);
  b.u32(0);
  b.u32(binaryNullIndex);
  b.u32(0);
  b.u32(1);
  b.u32(0);
  b.u32(0);
  b.str('Obj');
  b.str('TS');
  b.u32(2);
  b.leaf('Str', 'Icon', value: 'step.ico');
  b.u32(BinaryPropertyFlag.typed.bit);
  b.u32(0);
  b.u32(binaryNullIndex);
  b.u32(0);
  b.str('PreCond');
  b.u32(0);
  b.u32(0);
  b.u8(0);
  b.u32(2);
  // data root
  b.u32(BinaryPropertyFlag.valueFlags.bit);
  b.u32(0);
  b.str('SequenceFileData');
  b.str('Data');
  b.u32(4194304);
  b.u32(1);
  b.u32(BinaryPropertyFlag.value.bit);
  b.u32(0);
  b.str('Objs');
  b.str('Seq');
  b.str('[0]');
  b.str('[0]');
  b.u8(0);
  b.u32(0);
  b.u32(0);
  b.str('Sequence');
  b.str('MainSequence');
  b.u32(2);
  b.u32(0);
  b.u32(0);
  b.str('Obj');
  b.str('Locals');
  b.u32(3);
  b.leaf(
    'Num',
    'Voltage',
    value: 5.5,
    flags: BinaryPropertyFlag.comment.bit | BinaryPropertyFlag.numericFormat.bit | BinaryPropertyFlag.extData.bit,
  );
  b.nums('Readings', [1.25, 2.5]);
  b.leaf('Str', 'Quote', value: '\u201cdone\u201d');
  b.u32(BinaryPropertyFlag.value.bit);
  b.u32(0);
  b.str('Objs');
  b.str('Main');
  b.str('[0]');
  b.str('[0]');
  b.u8(0);
  b.u32(BinaryPropertyFlag.typed.bit);
  b.u32(0);
  b.str('Step');
  b.u32(1);
  b.str('Measure it');
  b.u32(1);
  b.u32(0);
  b.u32(0);
  b.u32(binaryNullIndex);
  b.str('TS');
  b.u32(1);
  b.u32(BinaryPropertyFlag.value.bit);
  b.u32(0);
  b.u32(binaryNullIndex);
  b.str('PreCond');
  b.str('Locals.Voltage > 1');
  b.u32(0);
  b.u32(0);
  b.u32(0);
  return b.finish(terminateLast: terminateLast, tail: tail);
}

void main() {
  group('Tof1Header', () {
    test('reads every fixed field and derives the generation', () {
      final header = Tof1Header.parse(_synthetic())!;
      expect(header.fileType, 'SequenceFile');
      expect(header.productName, 'TestStand');
      expect(header.productVersion, '2021 SP1 (21.1.0.49154)');
      expect(header.fileVersion, 962);
      expect(header.generation, Tof1Generation.ts2014);
      expect(header.hasBodyMarker, isTrue);
      expect(header.rootAttributes['fileversion'], '962');
      expect(header.toSeqFileHeader().fileVersion, '962');
    });

    test('generations switch at the corpus file versions', () {
      expect(Tof1Generation.of(577), Tof1Generation.ts4);
      expect(Tof1Generation.of(755), Tof1Generation.ts2013);
      expect(Tof1Generation.of(772), Tof1Generation.ts2013);
      expect(Tof1Generation.of(773), Tof1Generation.ts2014);
      expect(Tof1Generation.of(1022), Tof1Generation.ts2014);
      expect(Tof1Generation.ts4.hasProtectionBlock, isFalse);
      expect(Tof1Generation.ts2013.hasWideTimestamp, isFalse);
      expect(Tof1Generation.ts2014.hasWideTimestamp, isTrue);
    });

    test('rejects bytes that are not a TOF1 file', () {
      expect(Tof1Header.parse(Uint8List(0)), isNull);
      expect(Tof1Header.parse(Uint8List(0x600)), isNull);
      expect(Tof1Header.parse(ascii.encode('<?xml?>')), isNull);
    });

    test('classifies the whole header into decoded fields and zero padding', () {
      final bytes = _synthetic();
      final spans = Tof1Header.classify(bytes);
      var covered = 0;
      for (final (start, end, _) in spans) {
        covered += end - start;
      }
      expect(covered, Tof1HeaderField.body.offset);
      final (decoded, plumbing) = headerByteCoverage(bytes);
      expect(decoded + plumbing, Tof1HeaderField.body.offset);
    });
  });

  group('record grammar', () {
    test('decodes the type table, the data root and the pool', () {
      final decode = decodeTof1(_synthetic())!;
      expect(decode.error, isNull);
      final body = decode.grammar!;
      expect(body.types.map((t) => t.name), ['Expression', 'MyStep']);
      expect(body.types[0].root.kind, SeqValueClass.expression);
      expect(body.types[1].category, 1);
      expect(body.types[1].root.valueFlagsWord, 24);
      expect(body.types[1].orderNumber, 2);
      expect(body.data.resolvedClassName, 'SequenceFileData');
      expect(body.data.children.single.name, 'Seq');
      expect(body.pool.first, 'SequenceFileData');
      expect(body.tailWord, 0);
      final step =
          (body.data.children.single.elements!.single as BinaryRecord).child('Main')!.elements!.single as BinaryRecord;
      expect(step.typeName, 'MyStep');
      expect(step.resolvedClassName, 'Step');
      final preCond = step.child('TS')!.child('PreCond')!;
      expect(preCond.resolvedClassName, 'ExprValue', reason: 'the class is inherited through MyStep.TS.PreCond');
      expect(preCond.value, 'Locals.Voltage > 1');
    });

    test('lifts into the SeqFile model with inherited settings materialised', () {
      final file = parseSeqFile(_synthetic());
      expect(file.header.format, SeqFormat.binary);
      expect(file.header.fileVersion, '962');
      expect(file.types.map((t) => t.name), ['Expression', 'MyStep']);
      expect(file.typelistEntries!.map((e) => e.attributes['typelistordernum']), ['1', '2']);
      final sequence = file.sequences.single;
      expect(sequence.name, 'MainSequence');
      expect(sequence.locals.map((l) => l.name), ['Voltage', 'Readings', 'Quote']);
      final local = sequence.locals.first;
      expect((local.name, local.type, local.value), ('Voltage', 'Num', '5.5'));
      expect(local.comment, 'a comment');
      expect(local.raw.numericFormat, '%.2f');
      final step = sequence.main.single;
      expect(step.name, 'Measure it');
      expect(step.type, 'MyStep');
      expect(step.settings.precondition, 'Locals.Voltage > 1');
      final icon = step.raw.prop('TS')!.prop('Icon')!;
      expect(icon.scalar, 'step.ico');
      expect(icon.attributes[BinAttr.inherited], 'true');
      expect(step.raw.prop('TS')!.prop('PreCond')!.attributes.containsKey(BinAttr.inherited), isFalse);
    });

    test('every body byte is tiered and the undecoded spans are the named constant words', () {
      final body = decodeTof1(_synthetic())!.grammar!;
      final coverage = bodyByteCoverage(body);
      expect(coverage.bodyBytes, body.bytes.length);
      expect(coverage.recordUndecodedBytes, greaterThan(0));
      final spans = binaryUndecodedSpans(body);
      var spanned = 0;
      for (final span in spans) {
        spanned += span.end - span.start;
        for (var i = span.start; i < span.end; i++) {
          expect(body.tiers[i], BinaryByteTier.undecoded.index, reason: '${span.field} at $i');
        }
      }
      expect(spanned, coverage.recordUndecodedBytes);
      expect(spans.map((s) => s.field).toSet(), {
        BinaryUndecodedField.typeEntryWord,
        BinaryUndecodedField.recordFlagsHigh,
        BinaryUndecodedField.bodyTailWord,
      });
    });

    test('writes back byte-exactly and renames through the pool alone', () {
      final bytes = _synthetic();
      final original = inflateBinaryBody(bytes)!;
      final model = parseBinarySeqWriteModel(bytes)!;
      expect(model.writeBody(), original);
      expect(model.replacePoolEntry('Measure it', 'Measure it twice'), 1);
      final mutated = model.writeBody();
      expect(mutated.sublist(0, model.recordRegionLength), original.sublist(0, model.recordRegionLength));
      expect(parseSeqFile(model.writeFile()).sequences.single.main.single.name, 'Measure it twice');
      expect(model.f64Sites(5.5), hasLength(1));
      expect(model.replaceF64(5.5, 6.5), 1);
      expect(parseSeqFile(model.writeFile()).sequences.single.locals.first.value, '6.5');
    });

    test('stops with the offset when the bytes leave the grammar', () {
      final bytes = _synthetic();
      final body = inflateBinaryBody(bytes)!;
      body[0] = 0x7f;
      final header = Tof1Header.parse(bytes)!;
      expect(
        () => parseTof1Body(body, recordRegionLength: header.recordRegionLength, generation: header.generation),
        throwsA(isA<Tof1FormatException>()),
      );
      final decode = decodeTof1(bytes, body: body)!;
      expect(decode.grammar, isNull);
      expect(decode.error, contains('Tof1FormatException'));
    });
  });

  group('stored doubles', () {
    test('every site points at its own eight bytes, past extdata and in arrays', () {
      final bytes = _synthetic();
      final body = inflateBinaryBody(bytes)!;
      final view = ByteData.sublistView(body);
      final model = parseBinarySeqWriteModel(bytes)!;
      expect(model.f64Values, [5.5, 1.25, 2.5]);
      for (final value in model.f64Values) {
        final site = model.f64Sites(value).single;
        expect(view.getFloat64(site, Endian.little), value, reason: 'site of $value');
      }
    });

    test('a Nums element changes its eight bytes and its array element alone', () {
      final bytes = _synthetic();
      final body = inflateBinaryBody(bytes)!;
      final model = parseBinarySeqWriteModel(bytes)!;
      final site = model.f64Sites(2.5).single;
      expect(model.replaceF64(2.5, 3.75), 1);
      final written = model.writeBody();
      for (var i = 0; i < body.length; i++) {
        if (i < site || i >= site + 8) expect(written[i], body[i], reason: 'byte $i outside the element');
      }
      final readings = parseSeqFile(model.writeFile()).sequences.single.locals[1];
      expect([for (final e in readings.raw.array!) e.scalar], ['1.25', '3.75']);
    });
  });

  group('pool encoding and framing', () {
    test('Windows-1252 decodes every byte and encodes it back', () {
      final bytes = Uint8List.fromList([0x41, 0x93, 0x94, 0x80, 0x81, 0x9d, 0xbb, 0xb5, 0xff]);
      final text = decodeWindows1252(bytes, 0, bytes.length);
      expect(text, 'A\u201c\u201d\u20ac\u0081\u009d\u00bb\u00b5\u00ff');
      expect(encodeWindows1252(text), bytes);
      final all = Uint8List.fromList([for (var b = 0; b < 256; b++) b]);
      expect(encodeWindows1252(decodeWindows1252(all, 0, all.length)), all);
      expect(encodeWindows1252('\u03c0'), isNull);
    });

    test('pool strings read and write as Windows-1252', () {
      final bytes = _synthetic();
      final quote = parseSeqFile(bytes).sequences.single.locals[2];
      expect(quote.value, '\u201cdone\u201d');
      final model = parseBinarySeqWriteModel(bytes)!;
      final index = model.pool.indexOf('\u201cdone\u201d');
      expect(model.replacePoolEntry('\u201cdone\u201d', '\u2018ok\u2019'), 1);
      final (start, end) = model.poolEntryRange(index);
      expect(model.writeBody().sublist(start, end), [0x91, 0x6f, 0x6b, 0x92]);
      model.replacePoolEntry('\u2018ok\u2019', '\u03c0');
      expect(model.writeBody, throwsArgumentError);
    });

    test('an unterminated last string and bytes after the pool write back unchanged', () {
      for (final bytes in [
        _synthetic(terminateLast: false),
        _synthetic(tail: [7, 0, 9]),
      ]) {
        final body = inflateBinaryBody(bytes)!;
        expect(parseBinarySeqWriteModel(bytes)!.writeBody(), body);
      }
      final open = decodeTof1(_synthetic(terminateLast: false))!.grammar!;
      expect(open.lastStringTerminated, isFalse);
      expect(open.poolTail, isEmpty);
      final tailed = decodeTof1(_synthetic(tail: [7, 0, 9]))!.grammar!;
      expect(tailed.lastStringTerminated, isTrue);
      expect(tailed.poolTail, [7, 0, 9]);
      final coverage = bodyByteCoverage(tailed);
      expect(coverage.poolTailBytes, 3);
      expect(coverage.recordRegionBytes, tailed.recordRegionLength);
      final span = binaryUndecodedSpans(tailed).last;
      expect(
        (span.start, span.end, span.field),
        (tailed.bytes.length - 3, tailed.bytes.length, BinaryUndecodedField.poolTail),
      );
    });

    test('the sentinel count is the null indices the parser read, not aligned words', () {
      final analysis = analyzeBinary(_synthetic())!;
      expect(analysis.decode!.grammar!.nullIndexCount, 6);
      expect(analysis.layout!.sentinelCount, 6);
    });
  });

  group('array bounds', () {
    test('counts past maxArrayElements are reported as null, never wrapped', () {
      expect(arrayBoundCount('[0][0]', '[65536][65536]'), isNull);
      expect(arrayBoundCount('[0][0][0]', '[2097151][2097151][2097151]'), isNull);
      expect(arrayBoundCount('[0]', '[99999999999999999999]'), isNull);
      expect(arrayBoundCount('[0]', '[${maxArrayElements - 1}]'), maxArrayElements);
      expect(arrayBoundCount('[0]', '[$maxArrayElements]'), isNull);
    });

    test('an oversized array stops the parse with a FormatException', () {
      final b = _BodyBuilder();
      b.s('SequenceFileData');
      b.u32(0);
      b.u32(BinaryPropertyFlag.value.bit);
      b.u32(0);
      b.str('Nums');
      b.str('Data');
      b.str('[0][0]');
      b.str('[2097151][2097151]');
      b.u32(0);
      final bytes = b.finish();
      expect(decodeTof1(bytes)!.error, contains('exceed'));
      expect(() => parseSeqFile(bytes), throwsFormatException);
      expect(SeqDocument.parse(bytes), isA<BinarySeqDocument>());
    });
  });

  group('catalogues', () {
    test('the known flag mask is the union of the flags and nothing else', () {
      expect(BinaryPropertyFlag.knownMask, BinaryPropertyFlag.values.fold(0, (m, f) => m | f.bit));
      expect(BinaryPropertyFlag.knownMask & 0x400, 0);
    });

    test('numeric representations are looked up by their code', () {
      for (final representation in BinaryNumericRepresentation.values) {
        expect(BinaryNumericRepresentation.of(representation.code), representation);
      }
      expect(BinaryNumericRepresentation.of(1), isNull);
      expect(BinaryNumericRepresentation.of(null), isNull);
    });
  });

  test('SeqDocument.parse carries the lifted model of a grammar-conforming body', () {
    final doc = SeqDocument.parse(_synthetic()) as BinarySeqDocument;
    expect(doc.partialFile!.binary, isNotNull);
    expect(doc.partialFile!.sequences.single.main.single.name, 'Measure it');
    expect(doc.objectNames, ['MainSequence', 'Measure it']);
  });

  group('recon lenses for bodies outside the grammar', () {
    Uint8List poolOnly() {
      final pool = <int>[];
      for (final n in [
        'PaddingNameToExceedTheSixtyFourByteInflateGuardInThisTest',
        'SequenceFileData',
        'MainSequence',
        'Step',
        'Locals',
        'Parameters',
        r'My Computer\Lib\Read.vi',
        'Locals.x == 1',
        'ID#:abc123XYZ',
        '"6105A"',
      ]) {
        pool
          ..addAll(ascii.encode(n))
          ..add(0);
      }
      final header = Uint8List(0x108);
      header.setAll(0, ascii.encode('TOF1'));
      header.setAll(0x0a, ascii.encode('SequenceFile'));
      header.setAll(0x40, ascii.encode('TestStand'));
      return Uint8List.fromList([...header, ...zlib.encode(pool)]);
    }

    test('a marker-less header still inflates and the string lenses apply', () {
      final analysis = analyzeBinary(poolOnly())!;
      expect(analysis.grammarApplies, isFalse);
      expect(analysis.strings.map((s) => s.text), contains('MainSequence'));
      expect(analysis.layout!.stringCount, greaterThanOrEqualTo(5));
      expect(analysis.objectNames, contains('MainSequence'));
      expect(analysis.modulePaths, [r'My Computer\Lib\Read.vi']);
      expect(analysis.stepReferences, ['ID#:abc123XYZ']);
      expect(analysis.expressions, ['Locals.x == 1']);
      expect(analysis.quotedLiterals, ['"6105A"']);
      expect(binaryBodyStrings(poolOnly()).map((s) => s.text), contains('Step'));
      expect(() => parseSeqFile(poolOnly()), throwsFormatException);
    });

    test('pool-string classifier predicates', () {
      final cases = <(String, bool Function(String), bool)>[
        (r'My Computer\ExcelReadWrite\Excel_Read.vi', isBinaryModulePath, true),
        (r'SubSequences\2-Gerilim\AC_Gerilim.seq', isBinaryModulePath, true),
        (r'lib\native\driver.DLL', isBinaryModulePath, true),
        ('.vi', isBinaryModulePath, false),
        ('Excel_Read.vi', isBinaryModulePath, false),
        (r'notes\readme.txt', isBinaryModulePath, false),
        ('Locals.Voltage == 5', isBinaryExpression, true),
        ('RunState.LoopIndex += 1', isBinaryExpression, true),
        ('Abs(Locals.FD1) <= 0.1', isBinaryExpression, true),
        (r'ResStr("NI_STEPTYPES", "ACTION_DEF_STEP_NAME")', isBinaryExpression, true),
        ('(x == 0) ? "a" : "b"', isBinaryExpression, true),
        ('Status', isBinaryExpression, false),
        ('ID#:abc.Step.x', isBinaryExpression, false),
        (r'My Computer\Excel\Read.vi', isBinaryExpression, false),
        ('"6105A"', isBinaryQuotedLiteral, true),
        ('""', isBinaryQuotedLiteral, true),
        ('6105A', isBinaryQuotedLiteral, false),
        ('"open', isBinaryQuotedLiteral, false),
        ('"a" == "b"', isBinaryQuotedLiteral, false),
        ('"', isBinaryQuotedLiteral, false),
      ];
      for (final (text, predicate, want) in cases) {
        expect(predicate(text), want, reason: text);
      }
    });

    test('every lens is total on hostile input', () {
      final hostile = [
        Uint8List(0),
        ascii.encode('<?xml?>'),
        Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, 1, 2, 3]),
        Uint8List.fromList([1, 2, 3, 4, 5]),
        Uint8List(0x600)..setAll(0, ascii.encode('TOF1')),
      ];
      for (final bytes in hostile) {
        expect(inflateBinaryBody(bytes), isNull, reason: '$bytes');
        expect(analyzeBinary(bytes), isNull);
        expect(binaryBodyStrings(bytes), isEmpty);
        expect(binaryByteCoverage(bytes), isNull);
        expect(parseBinarySeqWriteModel(bytes), isNull);
        expect(binarySequenceNames(bytes), isEmpty);
      }
    });
  });

  group('fuzz hardening', () {
    Uint8List raw(List<int> tail) => Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, ...tail]);

    test('a zlib decompression bomb aborts instead of exhausting memory', () {
      final bomb = ZLibEncoder().convert(Uint8List(200 * 1024 * 1024));
      expect(bomb.length, lessThan(1024 * 1024));
      expect(inflateBinaryBody(raw([...Uint8List(0x514), ...bomb])), isNull);
    });

    test('a body just under the cap still inflates', () {
      expect(inflateBinaryBody(raw(ZLibEncoder().convert(Uint8List(1024 * 1024)))), isNotNull);
    });

    test('runaway counts and nesting bail with a FormatException', () {
      final region = BytesBuilder();
      for (var i = 0; i < 100000; i++) {
        region.add([0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, 1, 0, 0, 0]);
      }
      final body = region.toBytes();
      final file = _BodyBuilder._file(body, body.length - 12);
      expect(() => parseSeqFile(file), throwsFormatException);
      expect(decodeTof1(file)!.grammar, isNull);
      final huge = _BodyBuilder._file(Uint8List.fromList([0xff, 0xff, 0xff, 0x7f, ...Uint8List(64)]), 56);
      expect(() => parseSeqFile(huge), throwsFormatException);
    });
  });

  group('model helpers', () {
    test('formatSeqNumber prints integral doubles without a fraction', () {
      expect(formatSeqNumber(8192), '8192');
      expect(formatSeqNumber(0.01), '0.01');
      expect(formatSeqNumber(-3.5), '-3.5');
      expect(formatSeqNumber(2953567917), '2953567917');
      expect(formatSeqNumber(double.nan), 'NaN');
      expect(formatSeqNumber(double.negativeInfinity), '-Inf');
    });

    test('arrayBoundCount multiplies the extents of every dimension', () {
      expect(arrayBoundCount('[0]', '[]'), 0);
      expect(arrayBoundCount('[0]', '[0]'), 1);
      expect(arrayBoundCount('[0]', '[10]'), 11);
      expect(arrayBoundCount('[0][0]', '[1][2]'), 6);
      expect(arrayBoundCount('[1]', '[0]'), 0);
      expect(arrayBoundCount(null, '[3]'), 0);
      expect(arrayBoundCount('[x]', '[3]'), 0);
    });
  });
}
