import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/vi_demo.dart';

import 'util.dart';

/// The fetched snippet corpus (`Examples/Snippets/*.png` of the pinned
/// rcpacini/LabVIEW-VI-Snippet repo), or empty when not fetched. The extracted
/// repo keeps its tarball-root directory, so the PNGs are matched by their
/// in-repo path anywhere below the corpus folder.
List<File> snippetCorpusPngs() {
  final dir = repoDir(
    'packages/labwright_rsrc_parse/corpus/vi/rcpacini_LabVIEW-VI-Snippet',
  );
  if (dir == null) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (f) =>
            f.path.replaceAll(r'\', '/').contains('Examples/Snippets') &&
            f.path.endsWith('.png'),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main() {
  test('excessSupport rescales support against the chance rate', () {
    const cmp = PlacementComparison(
      perObject: [(oid: 1, support: 0.6), (oid: 2, support: 0.2)],
      chance: 0.2,
    );
    expect(cmp.objects, 2);
    expect(cmp.meanSupport, closeTo(0.4, 1e-9));
    // (0.6-0.2)/0.8 = 0.5 and (0.2-0.2)/0.8 = 0 → mean 0.25.
    expect(cmp.excessSupport, closeTo(0.25, 1e-9));
    expect(
      const PlacementComparison(perObject: [], chance: 0.5).excessSupport,
      0,
    );
  });

  testWidgets('decodeReferenceImage crops snippet chrome, not plain PNGs', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final rgba = Uint8List(60 * 60 * 4)..fillRange(0, 60 * 60 * 4, 0xff);
      final plain = await imageToPng(await imageFromRgba(rgba, 60, 60));
      final asIs = await decodeReferenceImage(plain);
      expect(asIs.snippetCropped, isFalse);
      expect((asIs.image.width, asIs.image.height), (60, 60));
      final snippet = spliceNiVi(plain, demoViBytes());
      final cropped = await decodeReferenceImage(snippet);
      // Interior [2, 58) × [26, 58) — header strip and dashed frame removed.
      expect(cropped.snippetCropped, isTrue);
      expect((cropped.image.width, cropped.image.height), (56, 32));
    });
  });

  testWidgets('placement scores a self-reference high and a shift low', (
    tester,
  ) async {
    // A structure frame + a node box: rendered, then compared against the
    // render itself (identity registration). Correct placement traces the
    // drawn outlines exactly; a 15-px shift must rank strictly lower.
    final root = ViHeapObject(oid: 1, kind: 0x7e, offset: 0)
      ..category = ViObjectKind.structure
      ..absBounds = const HeapRect(top: 0, left: 0, bottom: 160, right: 240);
    final loop = ViHeapObject(oid: 2, kind: 0x21, offset: 0)
      ..parentOid = 1
      ..category = ViObjectKind.structure
      ..absBounds = const HeapRect(top: 24, left: 24, bottom: 136, right: 216);
    final node = ViHeapObject(oid: 3, kind: 0x2f, offset: 0)
      ..parentOid = 2
      ..category = ViObjectKind.node
      ..absBounds = const HeapRect(top: 60, left: 80, bottom: 100, right: 120);
    final diagram = ViDiagram(sectionTag: 'BDHb', objects: [root, loop, node]);

    await tester.runAsync(() async {
      final raster = (await rasteriseBlockDiagram(diagram, scale: 1.0))!;
      final rgba = (await raster.image.toByteData())!.buffer.asUint8List();
      PlacementComparison at(double dx) => comparePlacement(
        diagram: diagram,
        raster: raster,
        registration: BdRegistration(scale: 1, dx: dx, dy: 0),
        referenceRgba: rgba,
        width: raster.image.width,
        height: raster.image.height,
      );
      final aligned = at(0);
      // The loop frame and node measure; the whole-extent root is excluded.
      expect(aligned.perObject.map((e) => e.oid), unorderedEquals([2, 3]));
      expect(aligned.meanSupport, greaterThan(0.95));
      expect(aligned.excessSupport, greaterThan(at(15).excessSupport));
    });
  });

  group('snippet corpus sweep', () {
    final pngs = snippetCorpusPngs();

    // Measured floors (well under the observed scores, see the sweep print):
    // a placement/rendering regression on any of these drops below its floor.
    const floors = <String, double>{
      'fg.png': 0.85,
      'example.png': 0.75,
      'sub_vi_missing.png': 0.65,
      'basic.png': 0.55,
      'PNG CRC32.png': 0.50,
      'large.png': 0.45,
      'vi_lib_dependency.png': 0.45,
      'missing_terminal.png': 0.25,
      'crc32_lookup_table.png': 0.15,
    };

    testWidgets('every snippet compares; placement ranks true placement', (
      tester,
    ) async {
      if (pngs.isEmpty) return;
      expect(pngs, hasLength(12));
      await tester.runAsync(() async {
        for (final f in pngs) {
          final png = f.readAsBytesSync();
          final vi = extractSnippetVi(png);
          expect(vi, isNotNull, reason: f.path);
          final diagram = bestBlockDiagram(buildViModel(vi!));
          expect(diagram, isNotNull, reason: f.path);
          final raster = (await rasteriseBlockDiagram(diagram!, scale: 1.0))!;
          final reference = await decodeReferenceImage(png);
          expect(reference.snippetCropped, isTrue, reason: f.path);
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
          );
          PlacementComparison at(BdRegistration registration) =>
              comparePlacement(
                diagram: diagram,
                raster: raster,
                registration: registration,
                referenceRgba: result.referenceRgba,
                referenceEdges: result.referenceEdges,
                width: reference.image.width,
                height: reference.image.height,
              );
          final placement = at(result.registration);
          final shifted = at(
            BdRegistration(
              scale: result.registration.scale,
              dx: result.registration.dx + 12,
              dy: result.registration.dy + 12,
            ),
          );
          final name = f.uri.pathSegments.last;
          // ignore: avoid_print
          print(
            'snippet $name: structural='
            '${(result.structural.score * 100).toStringAsFixed(1)}% '
            'placement=${(placement.excessSupport * 100).toStringAsFixed(1)}% '
            '(raw ${(placement.meanSupport * 100).toStringAsFixed(1)}%, '
            'chance ${(placement.chance * 100).toStringAsFixed(1)}%) '
            'over ${placement.objects} boxes '
            'shifted=${(shifted.excessSupport * 100).toStringAsFixed(1)}%',
          );
          expect(placement.chance, inExclusiveRange(0, 1), reason: name);
          // Excess is support read against chance — never above the raw rate.
          expect(
            placement.excessSupport,
            lessThanOrEqualTo(placement.meanSupport + 1e-9),
            reason: name,
          );
          // The metric must rank true placement above a displaced one wherever
          // enough boxes measure AND there is signal to rank on (a render that
          // matches the reference nowhere — an honest decode gap — scores 0 at
          // every offset; fewer boxes → too noisy to demand strictness).
          if (placement.objects >= 4 && placement.excessSupport > 0) {
            expect(
              placement.excessSupport,
              greaterThan(shifted.excessSupport),
              reason: name,
            );
          }
          final floor = floors[name];
          if (floor != null) {
            expect(
              placement.excessSupport,
              greaterThan(floor),
              reason: '$name fell below its measured placement floor',
            );
          }
        }
      });
    });
  });
}
