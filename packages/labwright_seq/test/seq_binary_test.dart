import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// A fake TOF1 file: magic + preamble + file-type token + a zlib body.
Uint8List _tof1(List<int> bodyBytes, {int pad = 0x100}) => Uint8List.fromList(
  (BytesBuilder()
        ..add(ascii.encode('TOF1'))
        ..add(List.filled(6, 0))
        ..add(ascii.encode('SequenceFile'))
        ..add(List.filled(pad, 0))
        ..add(zlib.encode(bodyBytes)))
      .toBytes(),
);

List<int> _f64le(double v) => (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List();

List<int> _u32le(int v) => [v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff];

List<int> _nulPool(List<String> names) => [
  for (final n in names) ...[...ascii.encode(n), 0],
];

/// A 48-byte named-scalar record: [tag][pad][nameRel][typeCode][f64] + 6 zero words.
List<int> _scalarRec({int tag = 0, int nameRel = 8, int typeCode = 99, double value = 42.0}) => [
  ..._u32le(tag),
  ..._u32le(0),
  ..._u32le(nameRel),
  ..._u32le(typeCode),
  ..._f64le(value),
  for (var i = 0; i < 6; i++) ..._u32le(0),
];

void main() {
  group('binary recon helpers', () {
    test('inflateBinaryBody locates + inflates the TOF1 zlib body', () {
      final body = inflateBinaryBody(_tof1(ascii.encode('SequenceFileData-MainSequence-Step' * 4)));
      expect(ascii.decode(body!), contains('MainSequence'));
    });

    test('binaryBodyStrings recovers the NUL-terminated name pool', () {
      final pool = _nulPool([
        'PaddingNameToExceedTheSixtyFourByteInflateGuardInThisTest',
        'SequenceFileData',
        'MainSequence',
        'Step',
        'Locals',
      ]);
      final names = binaryBodyStrings(_tof1(pool)).map((s) => s.text);
      expect(names, containsAll(['SequenceFileData', 'MainSequence', 'Step', 'Locals']));
    });

    test('binaryStringTable isolates the contiguous NUL-packed name table', () {
      final body = [
        0xAA,
        0xBB,
        0xCC,
        0x01,
        0x00,
        0x00,
        0x00,
        ...ascii.encode('xy'),
        0x00,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x00,
        ..._nulPool(['SequenceFileData', 'Data', 'Objs', 'Sequence', 'MainSequence', 'Parameters', 'Locals', 'Step']),
      ];
      final pool = binaryStringTable(_tof1(body)).map((s) => s.text).toList();
      expect(pool, containsAll(['SequenceFileData', 'Sequence', 'MainSequence', 'Step', 'Locals']));
      expect(pool, isNot(contains('xy')));
    });

    test('every lens returns null/empty on non-binary or hostile input, never throws', () {
      final hostile = [
        Uint8List(0),
        ascii.encode('<?xml?>'),
        Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, 1, 2, 3]),
        Uint8List.fromList([1, 2, 3, 4, 5]),
      ];
      for (final bytes in hostile) {
        expect(inflateBinaryBody(bytes), isNull, reason: '$bytes');
        expect(binaryBodyStrings(bytes), isEmpty);
        expect(binaryStringTable(bytes), isEmpty);
        expect(binaryModulePaths(bytes), isEmpty);
        expect(binaryStepReferences(bytes), isEmpty);
        expect(binaryExpressions(bytes), isEmpty);
        expect(binaryQuotedLiterals(bytes), isEmpty);
        expect(binaryScalarDoubles(bytes), isEmpty);
        expect(binaryNamedScalarRecords(bytes), isEmpty);
        expect(binaryNamedRecords(bytes), isEmpty);
      }
    });

    test('pool-string classifier predicates', () {
      final cases = <(String, bool Function(String), bool)>[
        (r'My Computer\ExcelReadWrite\Excel_Read.vi', isBinaryModulePath, true),
        (r'SubSequences\2-Gerilim\AC_Gerilim.seq', isBinaryModulePath, true),
        (r'lib\native\driver.DLL', isBinaryModulePath, true),
        (r'old\vis.llb', isBinaryModulePath, true),
        ('.vi', isBinaryModulePath, false),
        ('Status', isBinaryModulePath, false),
        ('Excel_Read.vi', isBinaryModulePath, false),
        (r'notes\readme.txt', isBinaryModulePath, false),
        (r'dir\tool.exe', isBinaryModulePath, false),
        ('Locals.Voltage == 5', isBinaryExpression, true),
        ('RunState.LoopIndex += 1', isBinaryExpression, true),
        ('Step.Result.Error.Occurred', isBinaryExpression, true),
        ('Abs(Locals.FD1) <= 0.1', isBinaryExpression, true),
        (r'ResStr("NI_STEPTYPES", "ACTION_DEF_STEP_NAME")', isBinaryExpression, true),
        ('(x == 0) ? "a" : "b"', isBinaryExpression, true),
        ('"a" == "b"', isBinaryExpression, true),
        ('Status', isBinaryExpression, false),
        ('Measurement 0', isBinaryExpression, false),
        ('ID#:abc.Step.x', isBinaryExpression, false),
        (r'My Computer\Excel\Read.vi', isBinaryExpression, false),
        ('"6105A"', isBinaryQuotedLiteral, true),
        ('"Unnamed Entry Point"', isBinaryQuotedLiteral, true),
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

    test('binaryScalarDoubles recovers clean inline IEEE-754 doubles, not noisy ones', () {
      final rec = [..._u32le(0x1c), ..._f64le(8192.0), ..._f64le(1.0), ..._f64le(3.14159265358979)];
      final pool = _nulPool([
        'SequenceFileData',
        'MainSequence',
        'StepGroupMain',
        'LocalsVarOne',
        'ResultListItem',
        'ParametersBlock',
      ]);
      final got = binaryScalarDoubles(_tof1([...rec, ...pool]));
      expect(got, containsAll(<double>[8192.0, 1.0]));
      expect(got, isNot(contains(3.14159265358979)));
    });

    test('binaryNamedScalarRecords pairs a named-property header with its f64', () {
      final pool = _nulPool(['PadName', 'Parameters', 'Locals', 'ResultList', 'StepEntry', 'SeqEntry']);
      final rec = _scalarRec();
      expect(rec, hasLength(48));
      final r = binaryNamedScalarRecords(_tof1([...rec, ...pool])).single;
      expect((r.name, r.rawTag, r.rawTypeCode, r.value), ('Parameters', 0, 99, 42.0));
    });

    test('binaryNamedRecords keeps consistently-tagged names, drops the rest', () {
      final pool = _nulPool(['PadName', 'Parameters', 'Locals', 'ResultList', 'StepX', 'SeqX']);
      final rec = [
        // Two consistent [tag=5][nameRel=8] pairs, two conflicting tags for rel 19.
        ..._u32le(0), ..._u32le(5), ..._u32le(8),
        ..._u32le(0), ..._u32le(5), ..._u32le(8),
        ..._u32le(0), ..._u32le(3), ..._u32le(19),
        ..._u32le(0), ..._u32le(4), ..._u32le(19),
        ..._u32le(0), ..._u32le(0), ..._u32le(0), ..._u32le(0),
      ];
      final recs = binaryNamedRecords(_tof1([...rec, ...pool]));
      expect(recs, hasLength(1));
      expect((recs.single.name, recs.single.count, recs.single.rawTag), ('Parameters', 2, 5));
    });

    test('dumpBinaryRecon reports recovered data + honest not-yet-decoded note', () {
      final pool = _nulPool(['PadName', 'Parameters', 'Locals', 'ResultList', 'StepEntry', 'SeqEntry']);
      final text = dumpBinaryRecon(_tof1([..._scalarRec(), ...pool]));
      expect(text, contains('=== Layout ==='));
      expect(text, contains('=== Named scalar values (1) ==='));
      expect(text, contains('Parameters = 42.0  (raw type 99, not modeled)'));
      expect(text, contains('record links not yet decoded'));
      expect(dumpBinaryRecon(ascii.encode('<?xml?>')), '(not a binary TOF1 file)');
    });
  });

  group('fuzz hardening: hostile inputs are total (null/bail), never crash or exhaust memory', () {
    Uint8List raw(List<int> tail) => Uint8List.fromList([0x54, 0x4f, 0x46, 0x31, ...tail]);

    test('a zlib decompression bomb aborts (null) instead of exhausting memory', () {
      final bomb = ZLibEncoder().convert(Uint8List(200 * 1024 * 1024));
      expect(bomb.length, lessThan(1 * 1024 * 1024), reason: 'the bomb must be tiny compressed');
      expect(inflateBinaryBody(raw(bomb)), isNull, reason: 'returning at all proves the cap fired');
    });

    test('a body just under the cap still inflates', () {
      expect(inflateBinaryBody(raw(ZLibEncoder().convert(Uint8List(1024 * 1024)))), isNotNull);
    });

    test('deeply nested typedef bodies bail instead of overflowing the stack', () {
      // 100k self-nesting descriptor nodes ([flags][0][DELIM][nameIdx][childCount=1]):
      // each recurses one level, so an uncapped parse would blow the Dart stack.
      final region = BytesBuilder();
      for (var i = 0; i < 100000; i++) {
        region
          ..add(_u32le(0))
          ..add(_u32le(0))
          ..add(_u32le(0xffffffff))
          ..add(_u32le(1))
          ..add(_u32le(1));
      }
      final file = raw(ZLibEncoder().convert(region.toBytes()));
      expect(() => parseSeqFile(file), returnsNormally);
      expect(() => binaryTypeRecords(file), returnsNormally);
    });
  });

  group('SeqDocument.parse dispatches on format and degrades honestly', () {
    test('XML → XmlSeqDocument (structured, typed lens)', () {
      final xml = Uint8List.fromList([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(
          "<?xml version='1.0'?>\n"
          "<teststandfileheader type='SequenceFile' fileversion='920' productname='TestStand'>"
          "<typelist/><Data classname='Obj'><subprops>"
          "<Seq classname='Objs'><value lbound='[0]' ubound='[1]'><value>"
          "<Sequence name='MainSequence' classname='Obj'><subprops>"
          "<Main classname='Objs'><value lbound='[0]' ubound='[1]'>"
          "<value><Step typename='Statement' name='S1'/></value></value></Main>"
          '</subprops></Sequence></value></value></Seq></subprops></Data>'
          '</teststandfileheader>',
        ),
      ]);
      final doc = SeqDocument.parse(xml);
      expect(doc, isA<XmlSeqDocument>());
      expect(doc, isA<StructuredSeqDocument>());
      expect(doc.header.format, SeqFormat.xml);
      expect((doc as XmlSeqDocument).file.sequences.single.name, 'MainSequence');
    });

    test('legacy INI → IniSeqDocument (structured, typed lens)', () {
      final ini = ascii.encode(
        [
          '[__Header__]',
          'ProductName = "TestStand"',
          'Version = 354',
          'Type = "SequenceFile"',
          '',
          '[DEF, %OBJROOT]',
          'SF = SequenceFileData',
          '[DEF, SF]',
          'Seq = Objs',
          '%NAME = "Data"',
          '[DEF, SF.Seq]',
          '%[0] = Sequence',
          '[DEF, SF.Seq[0]]',
          'Main = Objs',
          '%NAME = "MainSequence"',
          '[DEF, SF.Seq[0].Main]',
          '%[0] = Step',
          '%TYPE: %[0] = "Action"',
          '[DEF, SF.Seq[0].Main[0]]',
          '%NAME = "myStep"',
          '',
        ].join('\n'),
      );
      final doc = SeqDocument.parse(ini);
      expect(doc, isA<IniSeqDocument>());
      expect(doc, isA<StructuredSeqDocument>());
      expect(doc.header.format, SeqFormat.ini);
      final seq = (doc as IniSeqDocument).file.sequences.single;
      expect((seq.name, seq.main.single.name, seq.main.single.type), ('MainSequence', 'myStep', 'Action'));
    });

    test('TOF1 → BinarySeqDocument (recon lenses)', () {
      final pool = _nulPool([
        'PaddingNameSoTheInflatedBodyExceedsTheSixtyFourByteGuardHere',
        'SequenceFileData',
        'MainSequence',
        'Step',
        'Locals',
        'Parameters',
      ]);
      final header = Uint8List(0x108);
      header.setAll(0, ascii.encode('TOF1'));
      header.setAll(0x0a, ascii.encode('SequenceFile'));
      header.setAll(0x40, ascii.encode('TestStand'));
      final doc = SeqDocument.parse(Uint8List.fromList([...header, ...zlib.encode(pool)]));
      expect(doc, isA<BinarySeqDocument>());
      expect(doc.header.format, SeqFormat.binary);
      expect(doc.header.productName, 'TestStand');
      final bin = doc as BinarySeqDocument;
      expect(bin.inflatedSize, greaterThan(0));
      expect(bin.strings.map((s) => s.text), contains('MainSequence'));
      expect(bin.layout!.stringCount, greaterThanOrEqualTo(5));
    });

    test('arbitrary bytes → UnknownSeqDocument (no throw)', () {
      final doc = SeqDocument.parse(Uint8List.fromList([1, 2, 3, 4]));
      expect(doc, isA<UnknownSeqDocument>());
      expect(doc.header.format, SeqFormat.unknown);
    });

    test('a TOF1 header with a non-inflatable body degrades to recon-only (no throw)', () {
      final header = Uint8List(0x108);
      header.setAll(0, ascii.encode('TOF1'));
      header.setAll(0x0a, ascii.encode('SequenceFile'));
      final doc = SeqDocument.parse(Uint8List.fromList([...header, 0xde, 0xad, 0xbe, 0xef]));
      final bin = doc as BinarySeqDocument;
      expect(bin.partialFile, isNull);
      expect(bin.inflatedSize, 0);
      expect(bin.header.fileType, 'SequenceFile');
    });
  });
}
