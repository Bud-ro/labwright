import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'prim_icon_extraction.dart';

/// Writes `assets/prim_icons/prim<id>.png` from the snippet references:
///     flutter test tool/extract_prim_icons.dart --dart-define=EXTRACT_PRIM_ICONS=1
void main() {
  const enabled = String.fromEnvironment('EXTRACT_PRIM_ICONS');
  testWidgets('regenerate the primitive icon assets', (tester) async {
    if (enabled.isEmpty) {
      markTestSkipped('pass --dart-define=EXTRACT_PRIM_ICONS=1 to generate');
      return;
    }
    final extraction = await extractPrimIcons(tester);
    final appDir = extraction.appDir;
    final outDir = extraction.assetDir;
    final pending = extraction.pending;
    final failed = extraction.failed;
    final observedKeys = extraction.observedKeys;
    final skippedLowQuality = extraction.skippedLowQuality;
    final verifiedKeys = extraction.verifiedKeys;
    final handKeys = extraction.handKeys;
    final renamed = extraction.renamed;
    String baseOf(String key) => key.replaceFirst(RegExp(r'_from\d+$'), '');
    final paletteList = extraction.palette;
    expect(
      primIconReproErrors(extraction),
      isEmpty,
      reason: 'the extraction algorithm no longer reproduces verified icons',
    );

    final manifest = StringBuffer(
      '# Primitive icon assets\n\n'
      'Generated from LabVIEW\'s own renders in the snippet corpus (see\n'
      'tool/extract_prim_icons.dart): per identity, the hard-edged samples\n'
      '(every colour in the node box tiles at least three pixels; renders\n'
      'that anti-alias the icon are set aside) are aligned and\n'
      'consensus-voted per pixel (attached wires and neighbour ink vanish\n'
      'where the samples disagree), edge-touching wire stubs are erased, the\n'
      'result is trimmed to its ink and the exterior background made\n'
      'transparent. Colours are the canonical ones of the inspector\'s colour\n'
      'aliases. An identity with no hard-edged render is cut from its\n'
      'anti-aliased ones and says so; where its silhouette is one the\n'
      'hard-edged icons share, its border is theirs and the row says which.\n'
      'Hand-edits welcome — the painter stamps these at natural size.\n\n'
      '| asset | op | size | sources |\n|---|---|---|---|\n',
    );
    var written = 0;
    manifest.writeln(
      '\nPalette (${paletteList.length} colours — every icon pixel is one of '
      'these): ${paletteList.map((c) => '#${c.toRadixString(16).padLeft(6, '0')}').join(' ')}\n',
    );
    final only = enabled == '1'
        ? const <String>{}
        : enabled.split(',').map((key) => key.trim()).toSet();
    for (final key in pending.keys.toList()..sort()) {
      if (only.isNotEmpty && !only.contains(baseOf(key))) continue;
      final e = pending[key]!;
      if (verifiedKeys.contains(key) || handKeys.contains(key)) {
        manifest.writeln(
          '| $key | (verified — committed asset authoritative) | | ${e.sources} |',
        );
        written++;
        continue;
      }
      final primId = key.startsWith('prim')
          ? int.parse(baseOf(key).substring(4))
          : null;
      final op = primId == null ? null : PrimOp.fromId(primId);
      final classCode = key.startsWith('class')
          ? int.parse(key.substring(5).split('_').first)
          : null;
      final file = op != null ? '${key}_${op.slug}.png' : '$key.png';
      File('${outDir.path}/$file').writeAsBytesSync(img.encodePng(e.icon));
      final label =
          op?.opName ??
          (classCode != null
              ? 'class 0x${classCode.toRadixString(16)}'
              : '(uncatalogued)');
      final base = baseOf(key);
      final inferred = extraction.inferredBorders[base];
      final softNote = extraction.softOnly.contains(base)
          ? ' — anti-aliased renders only, no hard-edged sample'
                '${inferred == null ? '' : '; $inferred'}'
          : '';
      final aside = extraction.antiAliased[base]?.length ?? 0;
      final asideNote = aside == 0 || softNote.isNotEmpty
          ? ''
          : ' ($aside anti-aliased render${aside == 1 ? '' : 's'} set aside)';
      manifest.writeln(
        '| $file | $label | ${e.icon.width}x${e.icon.height} | ${e.sources}$softNote$asideNote |',
      );
      written++;
    }
    for (final key in observedKeys) {
      if (!pending.containsKey(key) &&
          !failed.containsKey(key) &&
          !pending.keys.any((k) => baseOf(k) == key)) {
        failed[key] = 'every sample came from a low-registration snippet';
      }
    }
    for (final key in extraction.watermarkedOnlyKeys) {
      if (handKeys.contains(key)) {
        manifest.writeln(
          '| ${_assetFileOf(outDir, key) ?? key} | ${PrimOp.fromId(int.tryParse(key.replaceFirst('prim', '')) ?? -1)?.opName ?? '(uncatalogued)'} | | hand-drawn: seen only in watermarked snippets |',
        );
        written++;
      } else {
        failed[key] = 'seen only in watermarked snippets';
      }
    }
    if (extraction.watermarkedSnippets.isNotEmpty) {
      manifest.writeln(
        '\nSnippets left unharvested because their saving LabVIEW watermarks '
        'its renders (LVSR status flags): '
        '${extraction.watermarkedSnippets.join(', ')}\n',
      );
    }
    if (failed.isNotEmpty) {
      manifest.writeln(
        '\n## Identities without a usable asset (kept visible, never hidden)\n',
      );
      for (final e
          in (failed.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))) {
        manifest.writeln('- ${e.key}: ${e.value}');
      }
    }
    if (skippedLowQuality.isNotEmpty) {
      manifest.writeln(
        '\nSnippets excluded from harvesting (registration below the 0.7 '
        'placement gate): ${skippedLowQuality.toSet().join(', ')}\n',
      );
    }
    for (final f in Directory(outDir.path).listSync().whereType<File>()) {
      final m = RegExp(
        r'((?:prim\d+|class0x[0-9a-f]+)(?:_t\d+(?:_r[0-9a-f]+)?)?(?:_from\d+)?)(?:_[a-z0-9-]+)?\.png$',
      ).firstMatch(f.path);
      if (m == null) continue;
      final key = m.group(1)!;
      if (only.isNotEmpty && !only.contains(baseOf(key))) continue;
      if (renamed.containsKey(key) ||
          !pending.containsKey(key) &&
              !verifiedKeys.contains(key) &&
              !handKeys.contains(key)) {
        f.deleteSync();
      }
    }
    final manifestFile = File('${outDir.path}/MANIFEST.md');
    manifestFile.writeAsStringSync(
      only.isEmpty
          ? manifest.toString()
          : _manifestWithRowsReplaced(
              manifestFile.readAsStringSync(),
              manifest.toString(),
              only,
            ),
    );
    if (only.isNotEmpty) {
      // ignore: avoid_print
      print(
        're-cut ${only.join(', ')}; the catalog and every other row are untouched',
      );
      return;
    }

    final catalogFile = File('$appDir/lib/src/prim_icon_catalog.dart');
    final existing = catalogFile.readAsStringSync();
    final oldStatus = {
      for (final m in RegExp(
        r"'([a-z0-9_]+)': PrimIconStatus\.(\w+)",
      ).allMatches(existing))
        m.group(1)!: m.group(2)!,
    };
    final oldKeyOf = {for (final e in renamed.entries) e.value: e.key};
    final allKeys = {
      ...pending.keys,
      ...failed.keys,
      for (final e in oldStatus.entries)
        if (e.value != 'unverified' && !renamed.containsKey(e.key)) e.key,
    }.toList()..sort();
    final entries = StringBuffer(
      'const Map<String, PrimIconStatus> kPrimIconStatus = {\n',
    );
    for (final key in allKeys) {
      final status =
          oldStatus[key] ?? oldStatus[oldKeyOf[key] ?? ''] ?? 'unverified';
      entries.writeln("  '$key': PrimIconStatus.$status,");
    }
    entries.writeln('};');
    final begin = existing.indexOf(
      '// statuses are preserved — edit them freely.)',
    );
    final beginEnd = existing.indexOf('\n', begin) + 1;
    final end = existing.indexOf('// GENERATED-ENTRIES-END');
    catalogFile.writeAsStringSync(
      existing.substring(0, beginEnd) +
          entries.toString() +
          existing.substring(end),
    );
    // ignore: avoid_print
    print('wrote $written icon assets to ${outDir.path}');
  });
}

String _manifestWithRowsReplaced(
  String committed,
  String fresh,
  Set<String> only,
) {
  String? keyOf(String line) => RegExp(
    r'^\| ((?:prim|class)\d+(?:_t\d+(?:_r[0-9a-f]+)?)?(?:_from\d+)?)(?:_[a-z0-9-]+)?(?:\.png)? \|',
  ).firstMatch(line)?.group(1);
  final replacements = <String, String>{
    for (final line in fresh.split('\n'))
      if (keyOf(line) case final key? when only.contains(key)) key: line,
  };
  final out = <String>[];
  for (final line in committed.split('\n')) {
    final key = keyOf(line);
    if (key == null || !only.contains(key)) {
      out.add(line);
      continue;
    }
    if (replacements.remove(key) case final row?) out.add(row);
  }
  out.addAll(replacements.values);
  return out.join('\n');
}

/// The file name of the committed asset of [key] in [dir], or null.
String? _assetFileOf(Directory dir, String key) {
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (RegExp(
      '^$key(?:_(?!t\\d|r[0-9a-f]+(?:_|\\.)|from\\d)[a-z0-9-]+)?\\.png\$',
    ).hasMatch(name)) {
      return name;
    }
  }
  return null;
}
