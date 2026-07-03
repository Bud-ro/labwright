import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

/// Builds a 160-byte LVSR record: BCD version word at `@0`
/// (`[major][minor][stage][build]`, stage `0x80` = release), the block-diagram
/// password hash at `@96`, and the secondary hash at `@144`.
Uint8List _lvsr160({int verByte0 = 0x20, List<int>? hash96, List<int>? hash144}) {
  final b = Uint8List(160);
  b[0] = verByte0;
  b[1] = 0x00;
  b[2] = 0x80;
  b[3] = 0x00;
  final h96 = hash96 ?? emptyPasswordHash;
  final h144 = hash144 ?? emptyPasswordHash;
  for (var i = 0; i < 16; i++) {
    b[96 + i] = h96[i];
    b[144 + i] = h144[i];
  }
  return b;
}

void main() {
  group('decodeSaveRecord', () {
    test('decodes the BCD version word from a 160-byte record', () {
      final r = decodeSaveRecord(_lvsr160())!;
      expect(r.versionMajor, 20, reason: '0x20 BCD = 20 (LabVIEW 2020)');
      expect(r.versionMinor, 0);
      expect(r.stage, 0x80);
      expect(r.version, '20.0');
      expect(r.rawLength, 160);
      expect(decodeSaveRecord(_lvsr160(verByte0: 0x09))!.versionMajor, 9,
          reason: '0x09 BCD = 9 (LabVIEW 2009)');
    });

    test('reads the @96 password hash and reports protection state', () {
      final unset = decodeSaveRecord(_lvsr160())!;
      expect(unset.blockDiagramPasswordHash, emptyPasswordHash);
      expect(unset.isBlockDiagramPasswordProtected, isFalse);

      final protectedHash = List<int>.generate(16, (i) => i + 1);
      final prot = decodeSaveRecord(_lvsr160(hash96: protectedHash))!;
      expect(prot.blockDiagramPasswordHash, protectedHash);
      expect(prot.isBlockDiagramPasswordProtected, isTrue);
    });

    test('reads the @144 secondary hash from its own offset', () {
      final hash144 = List<int>.generate(16, (i) => 100 + i);
      final r = decodeSaveRecord(_lvsr160(hash144: hash144))!;
      expect(r.secondaryHash, hash144);
      expect(r.blockDiagramPasswordHash, emptyPasswordHash,
          reason: '@96 password hash is independent of the @144 slot');
      expect(() => r.secondaryHash!.add(0), throwsUnsupportedError,
          reason: 'the returned hash slot is read-only');
    });

    test('hash slots are gated on length', () {
      final b112 = Uint8List(112)..[0] = 0x12;
      b112[2] = 0x80;
      final r = decodeSaveRecord(b112)!;
      expect(r.blockDiagramPasswordHash, isNotNull,
          reason: '112 bytes reaches the @96 hash');
      expect(r.secondaryHash, isNull, reason: '112 bytes does not reach the @144 hash');

      final tiny = decodeSaveRecord(Uint8List.fromList([0x16, 0, 0x80, 0]))!;
      expect(tiny.versionMajor, 16);
      expect(tiny.blockDiagramPasswordHash, isNull,
          reason: '4 bytes is only the version word, no hash slots');
      expect(tiny.secondaryHash, isNull);

      expect(decodeSaveRecord(Uint8List.fromList([1, 2])), isNull,
          reason: 'too short for even the version word');
    });

    test('the LVSR catalog entry is confirmed', () {
      expect(blockInfo('LVSR').category, ViBlockCategory.settings);
      expect(blockInfo('LVSR').confidence, BlockConfidence.confirmed);
    });
  });
}
