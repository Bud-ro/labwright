import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

import 'util.dart';

/// A small synthetic block diagram: a loop frame, a named node inside it, and a
/// labeled numeric terminal — enough to exercise the renderer + oracle.
ViDiagram _synthDiagram() => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 300, 400),
  ...open(0x21, 2, tag: 0x1a), // While loop frame
  ...bounds(20, 20, 200, 360),
  ...open(0x2f, 3, tag: 0x1b), // node inside the loop
  ...bounds(60, 80, 92, 180),
  ...caption('Acquire.vi'),
  ...close(0x1b),
  ...close(0x1a),
  ...open(0x50, 4, tag: 0x1c), // numeric terminal outside
  ...bounds(240, 40, 257, 140),
  ...caption('count'),
  ...close(0x1c),
  ...close(),
]).blockDiagrams.first;

Directory? _corpusDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory(
      '${dir.path}/packages/labwright_rsrc_parse/corpus/vi',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Whether every drawable **non-wire** object's absolute rectangle lies inside
/// [content] — the layout invariant the view relies on (objects placed within
/// the canvas). Wires are exempt: their absolute anchoring is unverified and a
/// misanchored run can compose outside the object frame (see the wire caveat),
/// which is exactly why the content rect is built from the non-wire objects.
bool _allWithin(Iterable<ViHeapObject> drawable, Rect content) {
  for (final object in drawable) {
    if (object.category == ViObjectKind.wire) continue;
    final b = object.absBounds!;
    if (b.left < content.left ||
        b.top < content.top ||
        b.right > content.right ||
        b.bottom > content.bottom) {
      return false;
    }
  }
  return true;
}

void main() {
  group('compareRgba (pure)', () {
    Uint8List solid(int w, int h, int r, int g, int b) {
      final out = Uint8List(w * h * 4);
      for (var i = 0; i < out.length; i += 4) {
        out[i] = r;
        out[i + 1] = g;
        out[i + 2] = b;
        out[i + 3] = 0xff;
      }
      return out;
    }

    test('identical buffers report zero difference', () {
      final a = solid(4, 4, 10, 20, 30);
      final cmp = compareRgba(a, Uint8List.fromList(a), 4, 4);
      expect(cmp.meanAbsDiff, 0);
      expect(cmp.diffFraction, 0);
      expect(cmp.diff.every((v) => v == 0 || v == 0xff), isTrue);
    });

    test('a fully different buffer reports a large difference', () {
      final a = solid(4, 4, 0, 0, 0);
      final b = solid(4, 4, 255, 255, 255);
      final cmp = compareRgba(a, b, 4, 4);
      expect(cmp.meanAbsDiff, 255);
      expect(cmp.diffFraction, 1.0);
    });

    test('one changed pixel is a small fraction over the threshold', () {
      final a = solid(4, 4, 0, 0, 0);
      final b = Uint8List.fromList(a);
      b[0] = 200; // one channel of one pixel
      final cmp = compareRgba(a, b, 4, 4);
      expect(cmp.diffFraction, closeTo(1 / 16, 1e-9));
      expect(cmp.meanAbsDiff, greaterThan(0));
    });
  });

  testWidgets('rasterises a synthetic block diagram to a non-empty image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final raster = await rasteriseBlockDiagram(_synthDiagram());
      expect(raster, isNotNull);
      expect(raster!.image.width, greaterThan(0));
      expect(raster.image.height, greaterThan(0));
      final png = await imageToPng(raster.image);
      expect(png.length, greaterThan(0));
    });
  });

  testWidgets('a render diffed against itself is (near) identical', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final raster = await rasteriseBlockDiagram(_synthDiagram());
      final result = await compareToReference(raster!.image, raster.image);
      // Same pixels, same size, no letterbox loss.
      expect(result.comparison.meanAbsDiff, 0);
      expect(result.comparison.diffFraction, 0);
    });
  });

  // The BdOracleView drives real (engine-backed) async — off-screen rasterise
  // and image decode — so it is pumped inside runAsync, polling until its
  // FutureBuilder resolves past the initial spinner.
  Future<void> settleOracle(WidgetTester tester, Finder marker) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (marker.evaluate().isNotEmpty) return;
      }
    });
  }

  testWidgets('BdOracleView renders without a reference and with one', (
    tester,
  ) async {
    // Without a reference: shows only the clean-room render.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BdOracleView(diagram: _synthDiagram())),
      ),
    );
    await settleOracle(tester, find.text('Rendered (clean-room)'));
    expect(tester.takeException(), isNull);
    expect(find.text('Rendered (clean-room)'), findsOneWidget);
    expect(find.text('Reference'), findsNothing);

    // With a reference: shows render, reference and diff panes.
    final ref = await tester.runAsync(() async {
      final raster = await rasteriseBlockDiagram(_synthDiagram());
      return imageToPng(raster!.image);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BdOracleView(diagram: _synthDiagram(), referenceBytes: ref),
        ),
      ),
    );
    await settleOracle(tester, find.text('Absolute diff'));
    expect(tester.takeException(), isNull);
    expect(find.text('Rendered (clean-room)'), findsOneWidget);
    expect(find.text('Reference'), findsOneWidget);
    expect(find.text('Absolute diff'), findsOneWidget);
    expect(find.textContaining('mean abs diff'), findsOneWidget);
  });

  test('synthetic diagram objects fall within the content rect', () {
    final diagram = _synthDiagram();
    final drawable = bdDrawableObjects(diagram);
    expect(drawable, isNotEmpty);
    final content = bdContentRect(drawable, includeWires: false);
    expect(_allWithin(drawable, content), isTrue);
    // The node placed inside the loop frame is spatially within it.
    final loop = diagram.byId[2]!;
    final members = nodesWithin(loop, drawable);
    expect(members.map((m) => m.oid), contains(3));
  });

  // Corpus-backed: the BD view renders a real VI without error and every drawn
  // object lands within the diagram's content frame.
  group('corpus', () {
    final corpus = _corpusDir();
    const rel =
        'NEVSTOP-LAB_Communicable-State-Machine/'
        'NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/'
        'src/_TEST/test message before initialize.vi';

    testWidgets('BD view renders a corpus VI; objects within their frame', (
      tester,
    ) async {
      if (corpus == null) return;
      final file = File('${corpus.path}/$rel');
      if (!file.existsSync()) return;
      final model = buildViModel(file.readAsBytesSync());
      final diagrams = model.blockDiagrams;
      if (!diagrams.any((d) => d.objects.isNotEmpty)) return;

      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ViDiagramView(diagrams: diagrams)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('objects'), findsOneWidget);

      ViDiagram best = diagrams.first;
      for (final d in diagrams) {
        if (d.objects.where((o) => o.absBounds != null).length >
            best.objects.where((o) => o.absBounds != null).length) {
          best = d;
        }
      }
      final drawable = bdDrawableObjects(best);
      final content = bdContentRect(drawable, includeWires: false);
      expect(_allWithin(drawable, content), isTrue);
    });
  });

  // Optional reference-oracle dump: run with
  //   flutter test test/bd_oracle_test.dart \
  //     --dart-define=BD_VI=/abs/path/foo.vi \
  //     --dart-define=BD_REFERENCE=/abs/path/foo.bd.png
  // Writes build/bd_oracle/<name>.{render,reference,diff}.png for eyeballing.
  const viPath = String.fromEnvironment('BD_VI');
  const refPath = String.fromEnvironment('BD_REFERENCE');
  final refMode = viPath.isNotEmpty && refPath.isNotEmpty;
  testWidgets('reference oracle dump', (tester) async {
    final viFile = File(viPath);
    final refFile = File(refPath);
    if (!viFile.existsSync() || !refFile.existsSync()) return;
    final model = buildViModel(viFile.readAsBytesSync());
    final diagrams = model.blockDiagrams;
    ViDiagram? diagram;
    for (final d in diagrams) {
      if (d.objects.any((o) => o.absBounds != null)) {
        diagram = d;
        break;
      }
    }
    if (diagram == null) return;
    await tester.runAsync(() async {
      final raster = await rasteriseBlockDiagram(diagram!);
      final reference = await decodeImage(refFile.readAsBytesSync());
      final result = await compareToReference(raster!.image, reference);
      final out = Directory('build/bd_oracle')..createSync(recursive: true);
      final name = viFile.uri.pathSegments.last;
      File(
        '${out.path}/$name.render.png',
      ).writeAsBytesSync(await imageToPng(result.fitted));
      File(
        '${out.path}/$name.reference.png',
      ).writeAsBytesSync(await imageToPng(result.reference));
      File(
        '${out.path}/$name.diff.png',
      ).writeAsBytesSync(await imageToPng(result.diffImage));
      // ignore: avoid_print
      print(
        'bd_oracle $name: meanAbsDiff=${result.comparison.meanAbsDiff.toStringAsFixed(2)} '
        'diffFraction=${(result.comparison.diffFraction * 100).toStringAsFixed(1)}%',
      );
    });
  }, skip: !refMode);
}
