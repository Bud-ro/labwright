import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// Opt-in (it writes into lib/):
/// `flutter test test/placement_census_test.dart --dart-define=PRIM_PLACEMENT_CENSUS=1`
void main() {
  const enabled = String.fromEnvironment('PRIM_PLACEMENT_CENSUS');
  testWidgets(
    'census LabVIEW icon placements and write the table',
    (tester) async {
      if (enabled.isEmpty) {
        markTestSkipped(
          'pass --dart-define=PRIM_PLACEMENT_CENSUS=1 to generate',
        );
        return;
      }
      final pngs = snippetCorpusPngs();
      if (pngs.isEmpty) return;
      await loadRealTextFont();
      await tester.runAsync(() async {
        final icons = await loadPrimIcons();
        final grey = primIconsGreyLoaded();
        final artBytes = <int, Uint8List>{};
        final greyBytes = <int, Uint8List>{};
        for (final e in icons.entries) {
          artBytes[e.key] = (await e.value.base.toByteData())!.buffer
              .asUint8List();
        }
        for (final e in grey.entries) {
          greyBytes[e.key] = (await e.value.base.toByteData())!.buffer
              .asUint8List();
        }
        final census = <String, Map<(int, int), int>>{};
        for (final f in pngs) {
          final bytes = f.readAsBytesSync();
          final vi = extractSnippetVi(bytes);
          if (vi == null) continue;
          final bd = bestBlockDiagram(buildViModel(vi));
          if (bd == null) continue;
          final drawable = bdDrawableObjects(bd);
          final raster = await rasteriseBlockDiagram(
            bd,
            primIcons: icons,
            scale: 1.0,
            margin: 2,
            wires: bdVisibleWires(bd),
            drawable: drawable,
          );
          if (raster == null) continue;
          final reference = await decodeReferenceImage(bytes);
          if (!reference.snippetCropped) {
            reference.image.dispose();
            raster.image.dispose();
            continue;
          }
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
          );
          final reg = result.registration;
          final refPx = (await reference.image.toByteData())!.buffer
              .asUint8List();
          final rw = reference.image.width;
          final rh = reference.image.height;
          final hits = <(String, int, int, int, int)>[];
          final bias = <(int, int), int>{};
          for (final o in drawable) {
            final b = o.absBounds;
            if (b == null) continue;
            final key = primIconKeyOf(o);
            if (key == null) continue;
            final art = icons[key];
            if (art == null) continue;
            final aw = art.base.width, ah = art.base.height;
            final bw = b.right - b.left, bh = b.bottom - b.top;
            final cx = (b.left - raster.content.left + reg.dx).round();
            final cy = (b.top - raster.content.top + reg.dy).round();
            final px0 = cx + ((bw - aw) / 2).floor();
            final py0 = cy + ((bh - ah) / 2).floor();
            for (final px in [artBytes[key], greyBytes[key]]) {
              if (px == null) continue;
              for (var dy = -4; dy <= 4; dy++) {
                for (var dx = -4; dx <= 4; dx++) {
                  final ox = px0 + dx, oy = py0 + dy;
                  if (ox < 0 || oy < 0 || ox + aw > rw || oy + ah > rh)
                    continue;
                  var ok = true;
                  for (var y = 0; y < ah && ok; y++) {
                    for (var x = 0; x < aw; x++) {
                      final a = (y * aw + x) * 4;
                      if (px[a + 3] == 0) continue;
                      final r = ((oy + y) * rw + (ox + x)) * 4;
                      if (px[a] != refPx[r] ||
                          px[a + 1] != refPx[r + 1] ||
                          px[a + 2] != refPx[r + 2]) {
                        ok = false;
                        break;
                      }
                    }
                  }
                  if (!ok) continue;
                  final kn = key >= 0 ? 'prim$key' : 'class${-key}';
                  hits.add((kn, ox - cx, oy - cy, dx, dy));
                  if (aw == bw && ah == bh) {
                    bias[(dx, dy)] = (bias[(dx, dy)] ?? 0) + 1;
                  }
                }
              }
            }
          }
          reference.image.dispose();
          raster.image.dispose();
          final snipBias = bias.isEmpty
              ? (0, 0)
              : (bias.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .first
                    .key;
          for (final (kn, boxDx, boxDy, _, _) in hits) {
            final place = (boxDx - snipBias.$1, boxDy - snipBias.$2);
            (census[kn] ??= {})[place] = (census[kn]![place] ?? 0) + 1;
          }
        }
        final conflicts = <String>[];
        final entries = <String>[];
        final keys = census.keys.toList()
          ..sort((a, b) {
            final ac = a.startsWith('class'), bc = b.startsWith('class');
            if (ac != bc) return ac ? -1 : 1;
            return int.parse(
              a.replaceAll(RegExp(r'\D'), ''),
            ).compareTo(int.parse(b.replaceAll(RegExp(r'\D'), '')));
          });
        for (final kn in keys) {
          final c = census[kn]!;
          if (c.length > 1) {
            conflicts.add('$kn: $c');
            continue;
          }
          final e = c.entries.first;
          entries.add(
            "  '$kn': (dx: ${e.key.$1}, dy: ${e.key.$2}), // x${e.value}",
          );
        }
        expect(
          entries.length,
          greaterThan(40),
          reason: 'census found too few placements to trust a rewrite',
        );
        expect(
          conflicts,
          isEmpty,
          reason:
              'non-unanimous placements (fix the assets or the model):\n'
              '${conflicts.join('\n')}',
        );
        final appDir = repoDir('apps/labwright_vi_inspector')!.path;
        final catalogFile = File('$appDir/lib/src/prim_icon_catalog.dart');
        final existing = catalogFile.readAsStringSync();
        const beginMark = '// GENERATED-PLACEMENT-BEGIN\n';
        const endMark = '// GENERATED-PLACEMENT-END';
        final begin = existing.indexOf(beginMark) + beginMark.length;
        final end = existing.indexOf(endMark);
        final only = enabled == '1'
            ? const <String>{}
            : enabled.split(',').map((key) => key.trim()).toSet();
        final rows = only.isEmpty
            ? entries
            : _rowsWithReplacements(
                existing.substring(begin, end),
                entries,
                only,
              );
        catalogFile.writeAsStringSync(
          '${existing.substring(0, begin)}'
          'const Map<String, ({int dx, int dy})> kPrimIconPlacement = {\n'
          '${rows.join('\n')}\n'
          '};\n'
          '${existing.substring(end)}',
        );
        // ignore: avoid_print
        print(
          only.isEmpty
              ? 'wrote ${entries.length} measured placements'
              : 're-measured ${only.join(', ')}; every other row is untouched',
        );
      });
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

List<String> _rowsWithReplacements(
  String committed,
  List<String> fresh,
  Set<String> only,
) {
  String? keyOf(String row) =>
      RegExp(r"^\s*'([a-z0-9_]+)':").firstMatch(row)?.group(1);
  final replacements = <String, String>{
    for (final row in fresh)
      if (keyOf(row) case final key? when only.contains(key)) key: row,
  };
  final rows = <String>[];
  for (final row in committed.split('\n')) {
    final key = keyOf(row);
    if (key == null) continue;
    if (!only.contains(key)) {
      rows.add(row);
      continue;
    }
    if (replacements.remove(key) case final replacement?) rows.add(replacement);
  }
  rows.addAll(replacements.values);
  return rows;
}
