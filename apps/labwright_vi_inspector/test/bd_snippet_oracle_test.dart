import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/vi_demo.dart';

import 'util.dart';

/// The fetched snippet corpus across both pinned oracle repos, or empty when
/// not fetched. The extracted repos keep their tarball-root directory, so the
/// PNGs are matched by their in-repo path anywhere below the corpus folder.
/// Snippet-ness itself is decided by extraction, not listing: the repos' plain
/// art PNGs carry no niVI and are filtered here.
List<File> snippetCorpusPngs() {
  final files = <File>[];
  for (final repo in const [
    'rcpacini_LabVIEW-VI-Snippet',
    'rcpacini_VI-Snippets',
  ]) {
    final dir = repoDir('packages/labwright_rsrc_parse/corpus/vi/$repo');
    if (dir == null) continue;
    files.addAll(
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .where((f) => extractSnippetVi(f.readAsBytesSync()) != null),
    );
  }
  return files..sort((a, b) => a.path.compareTo(b.path));
}

ViDataType? _artKindOf(ViTypeKind kind) => switch (kind) {
  ViTypeKind.boolean => ViDataType.boolean,
  ViTypeKind.string => ViDataType.string,
  ViTypeKind.cluster => ViDataType.cluster,
  ViTypeKind.path => ViDataType.path,
  ViTypeKind.enumRing => ViDataType.enumU8,
  _ => null,
};

void main() {
  testWidgets('stop, bool T/F, and enum-pager chrome are byte-exact', (
    tester,
  ) async {
    // Reference-measured chrome: the while-loop stop terminal, boolean T/F
    // constant blocks (value = decoded constBool), and the enum/ring control
    // terminal's pager glyphs. Each pinned box must match the reference
    // byte-for-byte (dominant capture palette; fg-class captures differ only
    // by the known boolean-green variance and are not pinned).
    const expected = {
      'Tokenize URL.png': [('stop', 286, 262, 16, 16)],
      'crc8.png': [
        ('F', 284, 472, 16, 14),
        // Selector strips (chrome only; the value text region is AA text and
        // sits inside these two side windows' gap).
        ('selector-left', 554, 237, 10, 17),
        ('selector-right', 599, 237, 20, 17),
        // Thick-wire branch junction: the 2/4/6/6/4/2 diamond on the 2 px
        // LUT wire's fork at (512,178), plus the surrounding wire runs.
        ('junction', 506, 172, 13, 13),
        // Slack-headed prim departures resolved by the builtin-terminal
        // catalog ([bdPrimTerminalOf]): each box covers the wire's bend
        // column and arrival runs beside the head prim.
        ('slack-271', 378, 481, 33, 17),
        ('slack-686', 750, 304, 57, 17),
        // Straight 2-point stub runs between builtin terminals: the visible
        // gap between the two nodes' art ink (dotted boolean for 293).
        ('stub-293', 296, 473, 13, 15),
        ('stub-1393', 578, 274, 15, 15),
        ('stub-701', 715, 303, 17, 15),
        ('stub-704', 686, 303, 11, 15),
        ('stub-881', 895, 311, 17, 15),
        // Diagram-disable structure: a single 1px (153,153,153) rectangle
        // (no double line, no tint) — pinned as four border strips.
        ('disable-top', 184, 163, 239, 1),
        ('disable-bottom', 184, 255, 239, 1),
        ('disable-left', 184, 163, 1, 93),
        ('disable-right', 422, 163, 1, 93),
        // The disabled LUT chain's seam stubs: dimmed-blue ink on the row
        // t+16 at every prim abutment (straight-stub tier + the chain's
        // terminal-catalog entries).
        ('disable-seams', 246, 222, 159, 5),
      ],
      // The crc siblings' slack wires resolve through the same catalog
      // entries; each box covers the wire's bends and both arrivals.
      'crc16.png': [
        ('slack-271', 372, 484, 34, 11),
        ('slack-683', 782, 303, 29, 15),
      ],
      'crc32.png': [
        ('slack-2615', 291, 702, 34, 11),
        ('slack-2396', 736, 523, 29, 15),
        ('slack-3742', 1000, 517, 29, 25),
      ],
    };
    final pngs = snippetCorpusPngs().where(
      (f) => expected.keys.any((n) => f.path.endsWith('/' + n)),
    );
    if (pngs.length < expected.length) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await loadRealTextFont();
    await tester.runAsync(() async {
      for (final f in pngs) {
        final name = f.path.split('/').last;
        final bytes = f.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final scene = BdScene(bd);
        final icons = await loadPrimIcons();
        final raster = (await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: 1.0,
          margin: 2,
          scene: scene,
        ))!;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(
            bd,
            raster,
            drawable: scene.drawable,
          ),
        );
        reference.image.dispose();
        final reg = result.registration;
        final w = result.reference.width;
        final refB = result.referenceRgba;
        final ourB = (await result.fitted.toByteData())!.buffer.asUint8List();
        for (final (label, x0, y0, bw, bh) in expected[name]!) {
          var diff = 0;
          for (var y = y0; y < y0 + bh; y++) {
            for (var x = x0; x < x0 + bw; x++) {
              final rx = (x - raster.content.left + reg.dx).round();
              final ry = (y - raster.content.top + reg.dy).round();
              final i = (ry * w + rx) * 4;
              if (refB[i] != ourB[i] ||
                  refB[i + 1] != ourB[i + 1] ||
                  refB[i + 2] != ourB[i + 2]) {
                diff++;
              }
            }
          }
          expect(diff, 0, reason: name + ' ' + label + ' chrome');
        }
      }
    });
  });

  testWidgets('hatch phase derives per capture and rephases to the reference', (
    tester,
  ) async {
    // LabVIEW anchors the case-hatch lattice to its device brush origin at
    // capture time (not stored in the .vi), so the oracle measures each
    // reference's phase. Expected offsets are pinned from the captures; the
    // rephased render's hatch ring must then match the reference nearly
    // everywhere (the small remainder is border-terminal overdraw).
    const expected = {
      'crc8.png': ((x: 0, y: 0), 716, 0.95),
      'fg.png': ((x: 0, y: 2), 128, 0.95),
      'MD5.png': ((x: 2, y: 2), 5720, 0.95),
    };
    final pngs = snippetCorpusPngs().where(
      (f) => expected.keys.any((n) => f.path.endsWith('/$n')),
    );
    if (pngs.length < expected.length) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await loadRealTextFont();
    await tester.runAsync(() async {
      for (final f in pngs) {
        final name = f.path.split('/').last;
        final (want, caseOid, floor) = expected[name]!;
        final bytes = f.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final drawable = bdDrawableObjects(bd);
        final wires = bdVisibleWires(bd);
        final icons = await loadPrimIcons();
        Future<(BdRaster, BdOracleResult)> render(GlobalHatchOffset off) async {
          final raster = (await rasteriseBlockDiagram(
            bd,
            primIcons: icons,
            scale: 1.0,
            margin: 2,
            wires: wires,
            drawable: drawable,
            style: BdRenderStyle(hatchOffset: off),
          ))!;
          final reference = await decodeReferenceImage(bytes);
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
          );
          reference.image.dispose();
          return (raster, result);
        }

        final (raster, result) = await render(kNoHatchOffset);
        final derived = deriveHatchOffset(
          diagram: bd,
          raster: raster,
          registration: result.registration,
          referenceRgba: result.referenceRgba,
          width: result.reference.width,
          height: result.reference.height,
          errorStyle: false,
        );
        expect(derived, want, reason: '$name derived offset');

        final (raster2, result2) = await render(derived);
        final w = result2.reference.width, h = result2.reference.height;
        final refB = result2.referenceRgba;
        final ourB = (await result2.fitted.toByteData())!.buffer.asUint8List();
        bool dark(Uint8List im, int x, int y) {
          final i = (y * w + x) * 4;
          return (im[i] + im[i + 1] + im[i + 2]) ~/ 3 < 110;
        }

        final b = bd.byId[caseOid]!.absBounds!;
        var same = 0, total = 0;
        for (var y = b.top; y <= b.bottom; y++) {
          for (var x = b.left; x <= b.right; x++) {
            final d = [
              x - b.left,
              y - b.top,
              b.right - x,
              b.bottom - y,
            ].reduce((p, q) => p < q ? p : q);
            if (d > kBdHatchBand) continue;
            final rx = (x - raster2.content.left + result2.registration.dx)
                .round();
            final ry = (y - raster2.content.top + result2.registration.dy)
                .round();
            if (rx < 0 || ry < 0 || rx >= w || ry >= h) continue;
            total++;
            if (dark(refB, rx, ry) == dark(ourB, rx, ry)) same++;
          }
        }
        expect(
          same / total,
          greaterThan(floor),
          reason: '$name case $caseOid hatch ring after rephasing',
        );
      }
    });
  });

  testWidgets('measured terminal art matches its reference somewhere per key', (
    tester,
  ) async {
    // For each (datatype, direction) with measured art ([kBdTerminalArt]),
    // at least one terminal of that key in its source VI must render
    // byte-exact (siblings may be overdrawn by wires; the clean one proves
    // the art). Files chosen from the majority-vote winners' sources.
    const expected = {
      'crc8.png': [(ViDataType.u8, false), (ViDataType.boolean, false)],
      'crc32.png': [(ViDataType.u32, false)],
      'Tokenize URL.png': [(ViDataType.string, false)],
      'ProjectItems.png': [
        (ViDataType.cluster, false),
        (ViDataType.refnum, false),
      ],
      'Config_Escape.png': [(ViDataType.enumU8, false)],
    };
    final pngs = snippetCorpusPngs().where(
      (f) => expected.keys.any((n) => f.path.endsWith('/' + n)),
    );
    if (pngs.length < expected.length) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await loadRealTextFont();
    await tester.runAsync(() async {
      for (final f in pngs) {
        final name = f.path.split('/').last;
        final bytes = f.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        final scene = BdScene(bd);
        final icons = await loadPrimIcons();
        final raster = (await rasteriseBlockDiagram(
          bd,
          primIcons: icons,
          scale: 1.0,
          margin: 2,
          scene: scene,
        ))!;
        final reference = await decodeReferenceImage(bytes);
        final result = await compareToReference(
          raster.image,
          reference.image,
          lockScale: 1.0 / raster.scale,
          anchorRects: bdStructureAnchorRects(
            bd,
            raster,
            drawable: scene.drawable,
          ),
        );
        reference.image.dispose();
        final reg = result.registration;
        final w = result.reference.width;
        final refB = result.referenceRgba;
        final ourB = (await result.fitted.toByteData())!.buffer.asUint8List();
        for (final (dataType, indicator) in expected[name]!) {
          var bestDiff = 1 << 30;
          for (final o in scene.drawable) {
            final b = o.absBounds;
            if (o.kind != 0x16 ||
                b == null ||
                b.width != 32 ||
                b.height != 16 ||
                (o.isIndicator == true) != indicator ||
                (o.dataType ?? _artKindOf(o.typeKind)) != dataType) {
              continue;
            }
            var diff = 0;
            for (var y = b.top; y < b.top + 16; y++) {
              for (var x = b.left; x < b.left + 32; x++) {
                final rx = (x - raster.content.left + reg.dx).round();
                final ry = (y - raster.content.top + reg.dy).round();
                final i = (ry * w + rx) * 4;
                if (refB[i] != ourB[i] ||
                    refB[i + 1] != ourB[i + 1] ||
                    refB[i + 2] != ourB[i + 2]) {
                  diff++;
                }
              }
            }
            if (diff < bestDiff) bestDiff = diff;
          }
          expect(
            bestDiff,
            0,
            reason: name + ' ' + dataType.name + ' terminal art',
          );
        }
      }
    });
  });

  testWidgets('error cases derive their stripe phase and rephase to match', (
    tester,
  ) async {
    // A case displaying its "No Error" frame draws the green stripe band
    // ([bdErrorCaseOids] / [kBdErrorHatch]); the stripe lattice carries a
    // per-capture phase of its own, independent of the black hatch's. Both
    // derived offsets are pinned; the rephased green ring must then match the
    // reference (strict 4-class: green field / grey stripe / black / other).
    const expected = {
      'GetCurrentDirectory.png': ((x: 0, y: 0), (x: 2, y: 0), 2380, 0.95),
      'Read VI Blocks.png': ((x: 3, y: 0), (x: 1, y: 0), 8715, 0.95),
    };
    final pngs = snippetCorpusPngs().where(
      (f) => expected.keys.any((n) => f.path.endsWith('/$n')),
    );
    if (pngs.length < expected.length) {
      markTestSkipped('corpus not fetched');
      return;
    }
    await loadRealTextFont();
    await tester.runAsync(() async {
      for (final f in pngs) {
        final name = f.path.split('/').last;
        final (wantBlack, wantError, caseOid, floor) = expected[name]!;
        final bytes = f.readAsBytesSync();
        final bd = bestBlockDiagram(buildViModel(extractSnippetVi(bytes)!))!;
        expect(
          bdErrorCaseOids(bd),
          contains(caseOid),
          reason: '$name error-case detection',
        );
        final drawable = bdDrawableObjects(bd);
        final wires = bdVisibleWires(bd);
        final icons = await loadPrimIcons();
        Future<(BdRaster, BdOracleResult)> render(
          GlobalHatchOffset black,
          GlobalHatchOffset error,
        ) async {
          final raster = (await rasteriseBlockDiagram(
            bd,
            primIcons: icons,
            scale: 1.0,
            margin: 2,
            wires: wires,
            drawable: drawable,
            style: BdRenderStyle(hatchOffset: black, errorHatchOffset: error),
          ))!;
          final reference = await decodeReferenceImage(bytes);
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            anchorRects: bdStructureAnchorRects(bd, raster, drawable: drawable),
          );
          reference.image.dispose();
          return (raster, result);
        }

        final (raster, result) = await render(kNoHatchOffset, kNoHatchOffset);
        GlobalHatchOffset derive({required bool errorStyle}) =>
            deriveHatchOffset(
              diagram: bd,
              raster: raster,
              registration: result.registration,
              referenceRgba: result.referenceRgba,
              width: result.reference.width,
              height: result.reference.height,
              errorStyle: errorStyle,
            );
        final black = derive(errorStyle: false);
        final error = derive(errorStyle: true);
        expect((black, error), (wantBlack, wantError), reason: '$name offsets');

        final (raster2, result2) = await render(black, error);
        final w = result2.reference.width, h = result2.reference.height;
        final refB = result2.referenceRgba;
        final ourB = (await result2.fitted.toByteData())!.buffer.asUint8List();
        String cls(Uint8List im, int x, int y) {
          final i = (y * w + x) * 4;
          final r = im[i], g = im[i + 1], bl = im[i + 2];
          if (g > 200 && r < 200 && bl < 200) return 'green';
          if ((r + g + bl) ~/ 3 < 60) return 'black';
          if ((r - bl).abs() < 30 && r > 90 && r < 170) return 'grey';
          return 'other';
        }

        final b = bd.byId[caseOid]!.absBounds!;
        var same = 0, total = 0;
        for (var y = b.top; y <= b.bottom; y++) {
          for (var x = b.left; x <= b.right; x++) {
            final d = [
              x - b.left,
              y - b.top,
              b.right - x,
              b.bottom - y,
            ].reduce((p, q) => p < q ? p : q);
            if (d > kBdHatchBand) continue;
            final rx = (x - raster2.content.left + result2.registration.dx)
                .round();
            final ry = (y - raster2.content.top + result2.registration.dy)
                .round();
            if (rx < 0 || ry < 0 || rx >= w || ry >= h) continue;
            total++;
            if (cls(refB, rx, ry) == cls(ourB, rx, ry)) same++;
          }
        }
        expect(
          same / total,
          greaterThan(floor),
          reason: '$name case $caseOid green ring after rephasing',
        );
      }
    });
  });

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
      final raster = (await rasteriseBlockDiagram(
        diagram,
        scale: 1.0,
        margin: 2,
      ))!;
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
      'fg.png': 0.92,
      'sub_vi_missing.png': 0.92,
      'missing_terminal.png': 0.92,
      'vi_lib_dependency.png': 0.92,
      'Resolve Library Path.png': 0.92,
      'Pages.png': 0.90,
      'ProjectItems.png': 0.90,
      'VISA_Query.png': 0.88,
      'example.png': 0.85,
      'Tokenize URL.png': 0.85,
      'VISA_Open2.png': 0.85,
      'Symbols1Bit.png': 0.85,
      'Config_Load.png': 0.85,
      'ClassChildren.png': 0.85,
      'Config_Dump.png': 0.83,
      'Config_Load2.png': 0.83,
      'ClassesInMemory.png': 0.82,
      'Config_Dump2.png': 0.80,
      'Export Palette Image WMF.png': 0.80,
      'Excel_Variant_Elements.png': 0.78,
      'FileReadOnly.png': 0.78,
      'GenerateTree.png': 0.78,
      'Excel_Cell_to_Value.png': 0.78,
      'VISA_InterfaceType.png': 0.76,
      'Read Library Version.png': 0.75,
      'Page1.png': 0.70,
      'GetCurrentDirectory.png': 0.70,
      'WriteConsole.png': 0.70,
      'IconHeader.png': 0.70,
      'large.png': 0.70,
      'Read VI Blocks.png': 0.70,
      'Config_Escape.png': 0.68,
      'basic.png': 0.68,
      'crc8.png': 0.68,
      'crc16.png': 0.67,
      'MD5.png': 0.65,
      'crc32.png': 0.64,
      'Resolve Path.png': 0.62,
      'PNG CRC32.png': 0.60,
      'crc32_lookup_table.png': 0.60,
      'Excel_Read_XLSX.png': 0.60,
      'decorations_only.png': 0.60,
      'Excel_Cell_to_RowCol.png': 0.58,
      'ReverseBitsVim.png': 0.58,
    };

    testWidgets('every snippet compares; placement ranks true placement', (
      tester,
    ) async {
      if (pngs.isEmpty) return;
      // Real glyphs, not Ahem blocks — canvas text is part of what the
      // oracle measures.
      await loadRealTextFont();
      expect(pngs, hasLength(46));
      var placementSum = 0.0, shiftedSum = 0.0, measured = 0;
      await tester.runAsync(() async {
        for (final f in pngs) {
          final png = f.readAsBytesSync();
          final vi = extractSnippetVi(png);
          expect(vi, isNotNull, reason: f.path);
          final diagram = bestBlockDiagram(buildViModel(vi!));
          expect(diagram, isNotNull, reason: f.path);
          final raster = (await rasteriseBlockDiagram(
            diagram!,
            scale: 1.0,
            // The same ink+2px crop the production Oracle tab renders with.
            margin: 2,
          ))!;
          final reference = await decodeReferenceImage(png);
          expect(reference.snippetCropped, isTrue, reason: f.path);
          final result = await compareToReference(
            raster.image,
            reference.image,
            lockScale: 1.0 / raster.scale,
            anchorRects: bdStructureAnchorRects(diagram, raster),
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
          if (placement.objects > 0) {
            placementSum += placement.excessSupport;
            shiftedSum += shifted.excessSupport;
            measured++;
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
      // The metric ranks true placement above a 12-px displaced control **in
      // aggregate** across the corpus. Per-snippet strictness is deliberately
      // not asserted here: on a VI whose decode is systematically mismatched
      // (an honest gap the oracle exists to expose) both offsets score
      // near-noise and can tie — the metric's ranking property itself is
      // pinned by the synthetic self-reference test above.
      expect(measured, greaterThan(20));
      expect(
        placementSum / measured,
        greaterThan(shiftedSum / measured + 0.1),
        reason: 'placement no longer ranks above a displaced control',
      );
    });
  });
}
