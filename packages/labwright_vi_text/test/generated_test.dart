@Tags(['corpus'])
library;

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';
import 'package:test/test.dart';

import '../../../tool/corpus.dart';
import 'generated/crc8.g.dart';

void main() {
  test(
    'the generated crc8 source builds the snippet\'s VI section for section',
    () {
      final original = decodeSections(
        extractSnippetVi(snippetPng('crc8.png').readAsBytesSync())!,
      );
      final built = decodeSections(crc8.encode());
      expect(
        built.map((s) => (s.tag, s.index, s.wasCompressed)),
        original.map((s) => (s.tag, s.index, s.wasCompressed)),
      );
      for (var i = 0; i < original.length; i++) {
        expect(built[i].bytes, original[i].bytes, reason: original[i].tag);
      }
      expect(crc8.sections.whereType<HeapSection>().length, 2);
    },
  );
}
