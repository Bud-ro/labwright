@Tags(['corpus'])
library;

import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  test('every fetched snippet extracts to a parseable VI with a positioned BD', () async {
    final results = await decodeSnippetPngs(corpusViDir);
    final snippets = results.where((r) => r.$2 != null).toList();
    expect(snippets, isNotEmpty);
    for (final (path, positioned) in snippets) {
      expect(positioned, isTrue, reason: path);
    }
  });
}
