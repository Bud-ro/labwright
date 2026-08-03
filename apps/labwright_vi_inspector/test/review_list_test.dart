import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/prim_icon_catalog.dart';

import 'bd_snippet_oracle_test.dart' show snippetCorpusPngs;
import 'util.dart';

/// Writes the reviewer's run-down list: per snippet, the primitive icon keys
/// that appear on its diagram, with each key's op name and current review
/// status — so verifying a snippet verifies a known set of catalog entries.
///
/// Opt-in (it writes into the repo):
/// `flutter test test/review_list_test.dart --dart-define=PRIM_REVIEW_LIST=1`
void main() {
  const enabled = String.fromEnvironment('PRIM_REVIEW_LIST');
  testWidgets('write the per-snippet icon review list', (tester) async {
    if (enabled.isEmpty) {
      markTestSkipped('pass --dart-define=PRIM_REVIEW_LIST=1 to generate');
      return;
    }
    final pngs = snippetCorpusPngs();
    if (pngs.isEmpty) return;
    final out = StringBuffer(
      '# Icon review run-down\n\n'
      'Per snippet, the primitive icon keys on its diagram (dedup within the\n'
      'snippet). Statuses reflect lib/src/prim_icon_catalog.dart at\n'
      'generation time; regenerate with\n'
      '`flutter test test/review_list_test.dart --dart-define=PRIM_REVIEW_LIST=1`.\n',
    );
    final keysBySnippet = <String, Set<String>>{};
    await tester.runAsync(() async {
      for (final f in pngs) {
        final vi = extractSnippetVi(f.readAsBytesSync());
        if (vi == null) continue;
        final bd = bestBlockDiagram(buildViModel(vi));
        if (bd == null) continue;
        final keys = <String>{};
        for (final o in bd.objects) {
          final key = primIconKeyOf(o);
          if (key == null) continue;
          keys.add(key >= 0 ? 'prim$key' : 'class${-key}');
        }
        if (keys.isNotEmpty) keysBySnippet[f.uri.pathSegments.last] = keys;
      }
    });
    String describe(String key) {
      final op = key.startsWith('prim')
          ? PrimOp.fromId(int.parse(key.substring(4)))
          : null;
      final status = kPrimIconStatus[key];
      return '`$key`${op != null ? ' (${op.opName})' : ''}'
          '${status == null
              ? ' — no asset'
              : status == PrimIconStatus.verified || status == PrimIconStatus.verifiedHand
              ? ' ✓'
              : ''}';
    }

    for (final name in keysBySnippet.keys.toList()..sort()) {
      final keys = keysBySnippet[name]!.toList()..sort();
      out.writeln('\n## $name\n');
      for (final key in keys) {
        out.writeln('- ${describe(key)}');
      }
    }
    final appDir = repoDir('apps/labwright_vi_inspector')!.path;
    File(
      '$appDir/assets/prim_icons/REVIEW.md',
    ).writeAsStringSync(out.toString());
    // ignore: avoid_print
    print('wrote review list for ${keysBySnippet.length} snippets');
  });
}
