import 'package:labwright_viparse/labwright_viparse.dart';
import 'package:test/test.dart';

void main() {
  group('block catalog', () {
    test('the C4 record-heap set is exactly the four heap tags', () {
      for (final t in ['FPHb', 'BDHb', 'FPHc', 'BDHc']) {
        expect(isRecordHeapTag(t), isTrue, reason: '$t should be a record heap');
        expect(blockInfo(t).category, ViBlockCategory.recordHeap);
      }
    });

    test('compressed-but-not-heap blocks are NOT record heaps', () {
      // These were the false positives: compressed (or short look-alike) blocks
      // the old byte heuristic mis-read as heaps with a bogus content length.
      for (final t in ['VCTP', 'VICD', 'DFDS', 'TM80', 'GCDI', 'STRG']) {
        expect(isRecordHeapTag(t), isFalse, reason: '$t must not be walked as a heap');
      }
    });

    test('self-identifying blocks are categorised from their magic/evidence', () {
      expect(blockInfo('VCTP').category, ViBlockCategory.typeInfo);
      expect(blockInfo('VICD').category, ViBlockCategory.compiledCode);
      expect(blockInfo('MNGI').category, ViBlockCategory.image); // PNG magic
      expect(blockInfo('BDPW').category, ViBlockCategory.security); // MD5 hash
      expect(blockInfo('HLPP').category, ViBlockCategory.helpPath); // PTH0
      expect(blockInfo('VINS').category, ViBlockCategory.embeddedVi);
      for (final t in ['VCTP', 'VICD', 'MNGI', 'BDPW', 'HLPP', 'VINS', 'vers']) {
        expect(blockInfo(t).confidence, BlockConfidence.confirmed, reason: '$t is corpus/magic-confirmed');
      }
    });

    test('signature blocks are catalogued as identifiers with verified confidence', () {
      for (final t in ['RTSG', 'OBSG', 'CCSG', 'SCSR']) {
        expect(blockInfo(t).category, ViBlockCategory.identifier, reason: t);
        expect(blockInfo(t).confidence, BlockConfidence.confirmed, reason: t);
      }
      expect(blockInfo('MUID').category, ViBlockCategory.identifier);
      expect(blockInfo('MUID').confidence, BlockConfidence.likely);
      // the variable-length id tables stay tentative (framing undecoded).
      for (final t in ['NUID', 'SUID', 'BNID']) {
        expect(blockInfo(t).confidence, BlockConfidence.tentative, reason: t);
      }
    });

    test('tail-sweep characterizations: confirmed-constant and the PRT key fix', () {
      for (final t in ['VPDP', 'DLDR', 'GCPR']) {
        expect(blockInfo(t).confidence, BlockConfidence.confirmed, reason: t);
        expect(blockInfo(t).note, contains('constant'), reason: t);
      }
      // PRT is a 4-char tag with a trailing space.
      expect(blockInfo('PRT ').name, 'Print settings');
      expect(blockInfo('PRT').category, ViBlockCategory.unknown); // 3-char is not the tag
      // CPST/CPSP are boolean-text tables.
      expect(blockInfo('CPST').category, ViBlockCategory.text);
      expect(blockInfo('CPSP').category, ViBlockCategory.text);
      // DLLP is a PTH0 path.
      expect(blockInfo('DLLP').category, ViBlockCategory.helpPath);
    });

    test('an uncatalogued tag resolves to an honest unknown, never throws', () {
      final info = blockInfo('ZZZZ');
      expect(info.category, ViBlockCategory.unknown);
      expect(info.confidence, BlockConfidence.tentative);
      expect(info.name, contains('ZZZZ'));
      expect(isRecordHeapTag('ZZZZ'), isFalse);
    });

    test('every catalogued tag carries a non-empty name and note', () {
      // guards against a half-filled entry
      for (final t in ['FPHb', 'VCTP', 'VICD', 'LVSR', 'CONP', 'icl8', 'LIvi']) {
        final info = blockInfo(t);
        expect(info.name, isNotEmpty);
        expect(info.note, isNotEmpty);
        expect(info.tag, t);
      }
    });
  });
}
