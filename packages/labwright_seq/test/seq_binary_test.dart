import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

typedef _F = BinaryPropertyFlag;

/// Builds a `TOF1` body, interning strings into the pool as it goes.
final class _Body {
  final bytes = BytesBuilder();
  final pool = <String>[];

  int s(String? text) {
    if (text == null) return binaryNullIndex;
    final index = pool.indexOf(text);
    if (index >= 0) return index;
    pool.add(text);
    return pool.length - 1;
  }

  void u32(List<int> words) {
    final view = ByteData(4 * words.length);
    for (final (i, word) in words.indexed) {
      view.setUint32(4 * i, word, Endian.little);
    }
    bytes.add(Uint8List.sublistView(view));
  }

  void u8(int value) => bytes.addByte(value);

  void f64(double value) => bytes.add(Uint8List.sublistView(ByteData(8)..setFloat64(0, value, Endian.little)));

  void head(int flags, String? cls, String? name, [int? typeRef]) =>
      u32([flags, 0, s(cls), if (typeRef != null) typeRef, s(name)]);

  void leaf(String cls, String name, {Object? value, int flags = 0}) {
    head(flags | (value == null ? 0 : _F.value.bit), cls, name);
    switch (value) {
      case final double v:
        f64(v);
      case final String v:
        u32([s(v)]);
    }
    if (_F.comment.isSetIn(flags)) u32([s('a comment')]);
    if (_F.numericFormat.isSetIn(flags)) u32([s('%.2f')]);
    if (_F.extData.isSetIn(flags)) {
      u32([1, s('CLUST')]);
      u8(1);
      u8(0);
      u32([s('label')]);
    }
    u32([0]);
  }

  void nums(String name, List<double> values) {
    head(_F.value.bit, 'Nums', name);
    u32([s('[0]'), s('[${values.length - 1}]')]);
    values.forEach(f64);
    u32([0]);
  }

  Uint8List finish({bool terminateLast = true, List<int> tail = const []}) {
    u32([0, binaryNullIndex]);
    final recordRegionLength = bytes.length;
    u32([pool.length]);
    for (final (i, text) in pool.indexed) {
      bytes.add(encodeWindows1252(text)!);
      if (i < pool.length - 1 || terminateLast) u8(0);
    }
    bytes.add(tail);
    return file(bytes.takeBytes(), recordRegionLength);
  }

  static Uint8List file(Uint8List body, int recordRegionLength, {int? inflatedLength}) {
    final header = Tof1Header.blank()
      ..fileType = 'SequenceFile'
      ..productName = 'TestStand'
      ..productVersion = '2021 SP1 (21.1.0.49154)'
      ..fileVersion = 962
      ..recordRegionLength = recordRegionLength
      ..inflatedLength = inflatedLength ?? body.length;
    return (BytesBuilder()
          ..add(header.serialize())
          ..add(zlib.encode(body)))
        .takeBytes();
  }
}

/// Two typedefs (an `ExprValue` and a step type whose `TS.PreCond` is typed by the first) and a data root with one
/// sequence holding three locals and one step.
Uint8List _synthetic({bool terminateLast = true, List<int> tail = const []}) {
  final b = _Body();
  ['SequenceFileData', 'Data', 'Objs', 'Seq', '[0]', 'Sequence', 'MainSequence', 'Obj'].forEach(b.s);
  final versions = [b.s('21.0.0.49156'), b.s('21.1.0.49154'), b.s('21.0.0.0')];
  b.u32([2, _F.typeFlags.bit, 1, b.s('ExprValue'), b.s('Expression'), 3, 1650060499, 0, ...versions, 33554436]);
  b.u32([0, binaryNullIndex, 0, 0, 0]);
  b.u8(0);
  b.u32([1, _F.typeFlags.bit | _F.valueFlags.bit, 1, b.s('StepType'), b.s('MyStep'), 1, 1650060499, 0, ...versions]);
  b.u32([33554438, 24, 0, binaryNullIndex, 0, 1]);
  b.head(0, 'Obj', 'TS');
  b.u32([2]);
  b.leaf('Str', 'Icon', value: 'step.ico');
  b.head(_F.typed.bit, null, 'PreCond', 0);
  b.u32([0, 0]);
  b.u8(0);
  b.u32([2]);
  b.head(_F.valueFlags.bit, 'SequenceFileData', 'Data');
  b.u32([4194304, 1]);
  b.head(_F.value.bit, 'Objs', 'Seq');
  b.u32([b.s('[0]'), b.s('[0]')]);
  b.u8(0);
  b.head(0, 'Sequence', 'MainSequence');
  b.u32([2]);
  b.head(0, 'Obj', 'Locals');
  b.u32([3]);
  b.leaf('Num', 'Voltage', value: 5.5, flags: _F.comment.bit | _F.numericFormat.bit | _F.extData.bit);
  b.nums('Readings', [1.25, 2.5]);
  b.leaf('Str', 'Quote', value: '“done”');
  b.head(_F.value.bit, 'Objs', 'Main');
  b.u32([b.s('[0]'), b.s('[0]')]);
  b.u8(0);
  b.head(_F.typed.bit, 'Step', 'Measure it', 1);
  b.u32([1]);
  b.head(0, null, 'TS');
  b.u32([1]);
  b.head(_F.value.bit, null, 'PreCond');
  b.u32([b.s('Locals.Voltage > 1'), 0, 0, 0]);
  return b.finish(terminateLast: terminateLast, tail: tail);
}

void main() {
  group('Tof1Header', () {
    test('reads every fixed field and derives the generation', () {
      final header = Tof1Header.parse(_synthetic())!;
      expect(
        (header.fileType, header.productName, header.productVersion, header.fileVersion, header.hasBodyMarker),
        ('SequenceFile', 'TestStand', '2021 SP1 (21.1.0.49154)', 962, true),
      );
      expect((header.generation, header.rootAttributes['fileversion']), (Tof1Generation.ts2014, '962'));
      expect(Tof1Header.layout.isContiguous, isTrue);
    });

    test('generations switch at the corpus file versions', () {
      expect(
        [
          for (final v in [577, 755, 772, 773, 1022]) Tof1Generation.of(v),
        ],
        [
          Tof1Generation.ts4,
          Tof1Generation.ts2013,
          Tof1Generation.ts2013,
          Tof1Generation.ts2014,
          Tof1Generation.ts2014,
        ],
      );
    });

    test('rejects bytes that are not a TOF1 file', () {
      for (final bytes in [Uint8List(0), Uint8List(Tof1Header.size), Uint8List.fromList('<?xml?>'.codeUnits)]) {
        expect(Tof1Header.parse(bytes), isNull);
      }
    });
  });

  group('record grammar', () {
    test('decodes the type table, the data root and the pool', () {
      final body = decodeTof1(_synthetic());
      expect(body.types.map((t) => t.name), ['Expression', 'MyStep']);
      expect(body.types[0].root.kind, SeqValueClass.expression);
      final step = body.types[1];
      expect((step.category, step.root.valueFlagsWord, step.orderNumber), (1, 24, 2));
      expect((body.data.resolvedClassName, body.data.children.single.name), ('SequenceFileData', 'Seq'));
      expect((body.pool.first, body.tailWord), ('SequenceFileData', 0));
      final sequence = body.data.children.single.elements!.single as BinaryRecord;
      final measure = sequence.child('Main')!.elements!.single as BinaryRecord;
      expect((measure.typeName, measure.resolvedClassName), ('MyStep', 'Step'));
      final preCond = measure.child('TS')!.child('PreCond')!;
      expect(preCond.resolvedClassName, 'ExprValue', reason: 'the class is inherited through MyStep.TS.PreCond');
      expect(preCond.value, 'Locals.Voltage > 1');
    });

    test('lifts into the SeqFile model with inherited settings materialised', () {
      final file = parseSeqFile(_synthetic());
      expect((file.header.format, file.header.fileVersion), (SeqFormat.binary, '962'));
      expect(file.types.map((t) => t.name), ['Expression', 'MyStep']);
      expect(file.typelistEntries!.map((e) => e.attributes['typelistordernum']), ['1', '2']);
      final sequence = file.sequences.single;
      expect(sequence.name, 'MainSequence');
      expect(sequence.locals.map((l) => l.name), ['Voltage', 'Readings', 'Quote']);
      final local = sequence.locals.first;
      expect((local.type, local.value, local.comment, local.raw.numericFormat), ('Num', '5.5', 'a comment', '%.2f'));
      final step = sequence.main.single;
      expect((step.name, step.type, step.settings.precondition), ('Measure it', 'MyStep', 'Locals.Voltage > 1'));
      final ts = step.raw.prop('TS')!;
      expect((ts.prop('Icon')!.scalar, ts.prop('Icon')!.attributes[BinAttr.inherited]), ('step.ico', 'true'));
      expect(ts.prop('PreCond')!.attributes.containsKey(BinAttr.inherited), isFalse);
    });

    test('the undecoded spans are the constant words the model holds', () {
      final body = decodeTof1(_synthetic());
      final view = ByteData.sublistView(body.bytes);
      final spans = body.undecodedSpans;
      expect(spans.map((s) => s.field).toSet(), {
        BinaryUndecodedField.typeEntryWord,
        BinaryUndecodedField.recordFlagsHigh,
        BinaryUndecodedField.bodyTailWord,
      });
      for (final span in spans) {
        final want = span.field == BinaryUndecodedField.typeEntryWord ? 1 : 0;
        expect(view.getUint32(span.start, Endian.little), want, reason: '${span.field} at ${span.start}');
      }
      expect(body.undecodedRecordBytes, 4 * spans.length);
    });

    test('writes back byte-exactly and renames through the pool alone', () {
      final bytes = _synthetic();
      final original = inflateBinaryBody(bytes)!;
      final model = BinarySeqWriteModel.parse(bytes);
      expect(model.writeBody(), original);
      expect(model.replacePoolEntry('Measure it', 'Measure it twice'), 1);
      final region = model.recordRegionLength;
      expect(model.writeBody().sublist(0, region), original.sublist(0, region));
      expect(parseSeqFile(model.writeFile()).sequences.single.main.single.name, 'Measure it twice');
      expect(model.replaceF64(5.5, 6.5), 1);
      expect(parseSeqFile(model.writeFile()).sequences.single.locals.first.value, '6.5');
    });

    test('stops with the offset when the bytes leave the grammar', () {
      final bytes = _synthetic();
      final body = inflateBinaryBody(bytes)!..[0] = 0x7f;
      expect(
        () => decodeTof1(bytes, body: body),
        throwsA(isA<Tof1FormatException>().having((e) => e.bodyOffset, 'bodyOffset', 0)),
      );
    });
  });

  group('stored doubles', () {
    test('every slot points at its own eight bytes, past extdata and in arrays', () {
      final bytes = _synthetic();
      final view = ByteData.sublistView(inflateBinaryBody(bytes)!);
      final slots = BinarySeqWriteModel.parse(bytes).f64Slots;
      expect(slots.map((s) => s.value), [5.5, 1.25, 2.5]);
      for (final slot in slots) {
        expect(view.getFloat64(slot.offset, Endian.little), slot.value);
      }
    });

    test('a Nums element changes its eight bytes and its array element alone', () {
      final bytes = _synthetic();
      final body = inflateBinaryBody(bytes)!;
      final model = BinarySeqWriteModel.parse(bytes);
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
      expect(decodeWindows1252(bytes), 'A“”€\u0081\u009d»µÿ');
      final all = Uint8List.fromList([for (var b = 0; b < 256; b++) b]);
      expect(encodeWindows1252(decodeWindows1252(all)), all);
      expect(encodeWindows1252('π'), isNull);
    });

    test('pool strings read and write as Windows-1252', () {
      final bytes = _synthetic();
      expect(parseSeqFile(bytes).sequences.single.locals[2].value, '“done”');
      final model = BinarySeqWriteModel.parse(bytes);
      final index = model.pool.indexOf('“done”');
      expect(model.replacePoolEntry('“done”', '‘ok’'), 1);
      final (start, end) = model.poolEntryRange(index);
      expect(model.writeBody().sublist(start, end), [0x91, 0x6f, 0x6b, 0x92]);
      model.replacePoolEntry('‘ok’', 'π');
      expect(model.writeBody, throwsArgumentError);
    });

    test('an unterminated last string and bytes after the pool write back unchanged', () {
      final open = _synthetic(terminateLast: false), tailed = _synthetic(tail: [7, 0, 9]);
      for (final bytes in [open, tailed]) {
        expect(BinarySeqWriteModel.parse(bytes).writeBody(), inflateBinaryBody(bytes));
      }
      expect(decodeTof1(open).lastStringTerminated, isFalse);
      expect(decodeTof1(open).poolTail, isEmpty);
      final body = decodeTof1(tailed);
      expect(body.lastStringTerminated, isTrue);
      expect(body.poolTail, [7, 0, 9]);
      final span = body.undecodedSpans.last;
      expect(
        (span.start, span.end, span.field),
        (body.bytes.length - 3, body.bytes.length, BinaryUndecodedField.poolTail),
      );
    });
  });

  group('arrays', () {
    test('arrayBoundCount multiplies the extents of every dimension and never wraps', () {
      const cases = <(String?, String, int?)>[
        ('[0]', '[]', 0),
        ('[0]', '[0]', 1),
        ('[0]', '[10]', 11),
        ('[0][0]', '[1][2]', 6),
        ('[1]', '[0]', 0),
        (null, '[3]', 0),
        ('[x]', '[3]', 0),
        ('[0][0]', '[65536][65536]', null),
        ('[0][0][0]', '[2097151][2097151][2097151]', null),
        ('[0]', '[99999999999999999999]', null),
        ('[0]', '[${maxArrayElements - 1}]', maxArrayElements),
        ('[0]', '[$maxArrayElements]', null),
      ];
      for (final (lower, upper, count) in cases) {
        expect(arrayBoundCount(lower, upper), count, reason: '$lower..$upper');
      }
    });

    test('an oversized array stops the parse with a FormatException', () {
      final b = _Body()..u32([0]);
      b.head(_F.value.bit, 'Nums', 'Data');
      b.u32([b.s('[0][0]'), b.s('[2097151][2097151]'), 0]);
      final bytes = b.finish();
      expect(() => parseSeqFile(bytes), throwsA(isA<Tof1FormatException>()));
    });

    test('Refs elements carry no payload: the next record follows the bounds and writes back byte-exactly', () {
      final b = _Body()..u32([0]);
      b.head(0, 'SequenceFileData', 'Data');
      b.u32([2]);
      b.head(_F.value.bit, 'Refs', 'Handles');
      b.u32([b.s('[0]'), b.s('[3]'), 0]);
      b.leaf('Num', 'After', value: 2.5);
      final bytes = b.finish();
      final body = decodeTof1(bytes);
      final handles = body.data.children.first;
      expect(handles.kind, SeqValueClass.references);
      expect(handles.elements, [null, null, null, null]);
      expect(body.data.children.last.value, 2.5);
      expect(BinarySeqWriteModel.parse(bytes).writeBody(), inflateBinaryBody(bytes));
      expect(parseSeqFile(bytes).data.prop('Handles')!.array, hasLength(4));
    });
  });

  group('fuzz hardening', () {
    test('hostile input is refused', () {
      final honest = _Body.file(Uint8List(64), 32);
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList('<?xml?>'.codeUnits),
        Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, 1, 2, 3]),
        _Body.file(Uint8List(64), 32, inflatedLength: 65),
        Uint8List.sublistView(honest, 0, Tof1Header.size + 3),
      ]) {
        expect(inflateBinaryBody(bytes), isNull, reason: '$bytes');
        expect(() => decodeTof1(bytes), throwsFormatException);
      }
    });

    test('a zlib decompression bomb aborts at the declared length; a large honest body inflates', () {
      final bomb = ZLibEncoder().convert(Uint8List(200 * 1024 * 1024));
      expect(bomb.length, lessThan(1024 * 1024));
      final header = Uint8List.sublistView(_Body.file(Uint8List(0), 0, inflatedLength: 1024), 0, Tof1Header.size);
      expect(inflateBinaryBody(Uint8List.fromList([...header, ...bomb])), isNull);
      expect(inflateBinaryBody(_Body.file(Uint8List(1024 * 1024), 0)), hasLength(1024 * 1024));
    });

    test('runaway counts and nesting bail with a FormatException', () {
      final b = _Body();
      for (var i = 0; i < 100000; i++) {
        b.u32([0, 0, binaryNullIndex, 1, 1]);
      }
      final body = b.bytes.takeBytes();
      expect(() => parseSeqFile(_Body.file(body, body.length - 12)), throwsFormatException);
      final huge = Uint8List.sublistView(ByteData(68)..setUint32(0, 0x7fffffff, Endian.little));
      expect(() => parseSeqFile(_Body.file(huge, 56)), throwsFormatException);
    });
  });

  test('formatSeqNumber prints integral doubles without a fraction', () {
    expect(
      [
        for (final v in [8192.0, 0.01, -3.5, 2953567917.0, double.nan, double.negativeInfinity]) formatSeqNumber(v),
      ],
      ['8192', '0.01', '-3.5', '2953567917', 'NaN', '-Inf'],
    );
  });
}
