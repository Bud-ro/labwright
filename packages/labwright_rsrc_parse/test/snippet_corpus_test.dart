@Tags(['corpus'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import '../tool/corpus_base.dart';
import 'corpus_dirs.dart';

void main() {
  final repos = <(String, bool Function(String), int)>[
    (
      'rcpacini_LabVIEW-VI-Snippet',
      (p) => p.contains('Examples/Snippets'),
      12,
    ),
    (
      'rcpacini_VI-Snippets',
      (p) => !p.endsWith('VI_Anatomy.png') && !p.endsWith('isometric.png'),
      34,
    ),
  ];

  test('every snippet PNG extracts to a parseable VI with a positioned BD', () {
    for (final (repoDir, isSnippet, count) in repos) {
      final dir = Directory('${corpusViDir.path}/$repoDir');
      final pngs = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.png')).toList();
      bool inSnippets(File f) => isSnippet(f.path.replaceAll(r'\', '/'));
      final snippets = pngs.where(inSnippets).toList();
      expect(snippets, hasLength(count), reason: repoDir);
      for (final f in snippets) {
        final vi = extractSnippetVi(f.readAsBytesSync());
        expect(vi, isNotNull, reason: f.path);
        final model = buildViModel(vi!);
        final positioned = [
          for (final d in model.blockDiagrams) d.objects.where((o) => o.absBounds != null).length,
        ];
        expect(positioned.any((n) => n > 0), isTrue, reason: f.path);
      }
      for (final f in pngs.where((f) => !inSnippets(f))) {
        expect(extractSnippetVi(f.readAsBytesSync()), isNull, reason: f.path);
      }
    }
  });

  test('every fetched snippet collection extracts to a parseable VI with a positioned BD', () async {
    final snippets = Directory('${corpusBaseDir().path}/snippets');
    final sources = (jsonDecode(File('${snippets.path}/sources.json').readAsStringSync())['sources'] as List)
        .cast<Map<String, dynamic>>();
    for (final source in sources) {
      final repo = source['repo'] as String;
      final dir = Directory('${snippets.path}/bulk/${repo.replaceAll('/', '_')}');
      final results = await decodeSnippetPngs(dir);
      final decoded = results.where((r) => r.$2 != null).toList();
      expect(decoded, hasLength(source['files']), reason: repo);
      for (final (path, positioned) in decoded) {
        expect(positioned, isTrue, reason: path);
      }
    }
  });
}
