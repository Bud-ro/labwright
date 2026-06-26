import 'dart:convert';
import 'dart:typed_data';

import 'package:labwright_teststand/labwright_teststand.dart';
import 'package:test/test.dart';

const _ini = '''
[__Header__]
ProductName = "TestStand"
ProductVersion = 3.5.0.365
Version = 354
Type = "SequenceFile"

[DEF, %OBJROOT]
SF = SequenceFileData

[DEF, SF]
Seq = Objs
%NAME = "Data"

[SF]
%HI: Seq = [0]
%FLG: Seq = 4194304
Version = "0.0.0.0"

[DEF, SF.Seq]
%[0] = Sequence

[DEF, SF.Seq[0]]
Main = Objs
%NAME = "MainSequence"
''';

void main() {
  group('parseIniSeq', () {
    final f = parseIniSeq(_ini);

    test('recovers the header (Type/ProductName/Version)', () {
      expect(f.header.format, SeqFormat.ini);
      expect(f.header.fileType, 'SequenceFile');
      expect(f.header.productName, 'TestStand');
      expect(f.header.fileVersion, '354');
    });

    test('classifies DEF vs value sections by path', () {
      final objroot = f.sections.firstWhere((s) => s.path == '%OBJROOT');
      expect(objroot.isDef, isTrue);
      expect(objroot.members['SF'], 'SequenceFileData');

      final sfVal = f.sections.firstWhere((s) => s.path == 'SF' && !s.isDef);
      expect(sfVal.members['Version'], '"0.0.0.0"');
      // %-directives are separated from plain members.
      expect(sfVal.members.containsKey('%FLG: Seq'), isFalse);
      expect(sfVal.directives['%FLG: Seq'], '4194304');
      expect(sfVal.directives['%HI: Seq'], '[0]');
    });

    test('exposes object names via %NAME (unquoted)', () {
      final data = f.sections.firstWhere((s) => s.isDef && s.path == 'SF');
      expect(data.name, 'Data');
      final mainSeq =
          f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq[0]');
      expect(mainSeq.name, 'MainSequence');
    });

    test('array element type declaration is captured as a directive', () {
      final seqDef = f.sections.firstWhere((s) => s.isDef && s.path == 'SF.Seq');
      expect(seqDef.directives['%[0]'], 'Sequence');
    });

    test('detectSeqHeader now recovers the INI header (was null)', () {
      final bytes = Uint8List.fromList(latin1.encode(_ini));
      expect(detectSeqFormat(bytes), SeqFormat.ini);
      final h = detectSeqHeader(bytes);
      expect(h.fileType, 'SequenceFile');
      expect(h.productName, 'TestStand');
      expect(h.fileVersion, '354');
    });
  });
}
