import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/subvi_icon_resolver.dart';

import 'util.dart';

ViDiagram _synthDiagram() => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 300, 400),
  ...open(0x21, 2, tag: 0x1a),
  ...bounds(20, 20, 200, 360),
  ...open(0x2f, 3, tag: 0x1b),
  ...bounds(60, 80, 92, 180),
  ...caption('Acquire.vi'),
  ...close(0x1b),
  ...close(0x1a),
  ...open(0x50, 4, tag: 0x1c),
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
      b[0] = 200;
      final cmp = compareRgba(a, b, 4, 4);
      expect(cmp.diffFraction, closeTo(1 / 16, 1e-9));
      expect(cmp.meanAbsDiff, greaterThan(0));
    });
  });

  group('structural comparison (pure)', () {
    Uint8List canvasWith(int w, int h, List<(int, int, int, int)> darkRects) {
      final out = Uint8List(w * h * 4);
      for (var i = 0; i < out.length; i += 4) {
        out[i] = 0xff;
        out[i + 1] = 0xff;
        out[i + 2] = 0xff;
        out[i + 3] = 0xff;
      }
      for (final r in darkRects) {
        for (var y = r.$2; y < r.$4; y++) {
          for (var x = r.$1; x < r.$3; x++) {
            final i = (y * w + x) * 4;
            out[i] = 0;
            out[i + 1] = 0;
            out[i + 2] = 0;
          }
        }
      }
      return out;
    }

    test('identical images score a perfect 1.0', () {
      final a = canvasWith(16, 16, [(3, 3, 10, 10)]);
      final s = compareStructural(a, Uint8List.fromList(a), 16, 16);
      expect(s.inkIoU, 1.0);
      expect(s.edgeIoU, 1.0);
      expect(s.score, 1.0);
      expect(s.inkFractionRender, s.inkFractionReference);
    });

    test('disjoint drawn regions score near zero', () {
      final a = canvasWith(16, 16, [(1, 1, 6, 6)]);
      final b = canvasWith(16, 16, [(10, 10, 15, 15)]);
      final s = compareStructural(a, b, 16, 16);
      expect(s.inkIoU, 0.0);
      expect(s.edgeIoU, 0.0);
      expect(s.score, lessThan(0.05));
    });

    test(
      'drawing more of the reference content raises the structural score',
      () {
        final reference = canvasWith(24, 24, [(2, 2, 9, 9), (14, 14, 21, 21)]);
        final sparse = canvasWith(24, 24, [(2, 2, 9, 9)]);
        final full = canvasWith(24, 24, [(2, 2, 9, 9), (14, 14, 21, 21)]);
        final sparseScore = compareStructural(sparse, reference, 24, 24).score;
        final fullScore = compareStructural(full, reference, 24, 24).score;
        expect(fullScore, greaterThan(sparseScore));
      },
    );
  });

  group('content-bounds registration', () {
    Uint8List canvasWith(int w, int h, int l, int t, int r, int b) {
      final out = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 0xff);
      for (var y = t; y < b; y++) {
        for (var x = l; x < r; x++) {
          final i = (y * w + x) * 4;
          out[i] = 0;
          out[i + 1] = 0;
          out[i + 2] = 0;
        }
      }
      return out;
    }

    test('inkBoundsOf finds the tight ink rectangle', () {
      final rgba = canvasWith(20, 10, 5, 3, 12, 7);
      final bounds = inkBoundsOf(rgba, 20, 10);
      expect(bounds, isNotNull);
      expect(bounds!.left, 5);
      expect(bounds.top, 3);
      expect(bounds.right, 12);
      expect(bounds.bottom, 7);
    });

    test('inkBoundsOf returns null for a blank canvas', () {
      final rgba = canvasWith(8, 8, 0, 0, 0, 0);
      expect(inkBoundsOf(rgba, 8, 8), isNull);
    });

    testWidgets('registration aligns a shifted, rescaled render', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final render = await imageFromRgba(
          canvasWith(60, 60, 10, 10, 30, 20),
          60,
          60,
        );
        final reference = await imageFromRgba(
          canvasWith(200, 120, 140, 80, 180, 100),
          200,
          120,
        );
        final result = await compareToReference(render, reference);
        expect(result.registered, isTrue);
        expect(result.structural.inkIoU, greaterThan(0.5));
      });
    });

    testWidgets('same-size pair takes the fast path (no registration)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final a = await imageFromRgba(canvasWith(40, 40, 8, 8, 24, 24), 40, 40);
        final result = await compareToReference(a, a);
        expect(result.registered, isFalse);
        expect(result.comparison.meanAbsDiff, 0);
      });
    });
  });

  group('decoded object colours', () {
    test(
      'bdDecodedColor maps 24-bit rgb to an opaque colour, null to null',
      () {
        expect(bdDecodedColor(null), isNull);
        expect(bdDecodedColor(0x123456), const Color(0xFF123456));
        expect(bdDecodedColor(0xAB010203), const Color(0xFF010203));
      },
    );

    test('bdFillColor prefers the content colour over the background', () {
      final o = ViHeapObject(oid: 1, kind: 0x50, offset: 0)
        ..bgRgb = 0x111111
        ..contentRgb = 0x222222;
      expect(bdFillColor(o), const Color(0xFF222222));
      final bgOnly = ViHeapObject(oid: 2, kind: 0x50, offset: 0)
        ..bgRgb = 0x111111;
      expect(bdFillColor(bgOnly), const Color(0xFF111111));
      expect(bdFillColor(ViHeapObject(oid: 3, kind: 0x50, offset: 0)), isNull);
    });

    ViDiagram captionDiagram({int? rgb}) {
      final root = ViHeapObject(oid: 1, kind: 0x7e, offset: 0)
        ..category = ViObjectKind.structure
        ..absBounds = const HeapRect(top: 0, left: 0, bottom: 80, right: 220);
      final constObj = ViHeapObject(oid: 2, kind: 0x51, offset: 0)
        ..parentOid = 1
        ..category = ViObjectKind.terminal
        ..absBounds = const HeapRect(top: 24, left: 24, bottom: 44, right: 200)
        ..constText = 'report.txt'
        ..fgRgb = rgb;
      return ViDiagram(sectionTag: 'BDHb', objects: [root, constObj]);
    }

    ViDiagram framedDiagram({int? rgb}) {
      final root = ViHeapObject(oid: 1, kind: 0x7e, offset: 0)
        ..category = ViObjectKind.decoration
        ..absBounds = const HeapRect(top: 0, left: 0, bottom: 120, right: 160);
      final loop = ViHeapObject(oid: 2, kind: 0x21, offset: 0)
        ..parentOid = 1
        ..category = ViObjectKind.structure
        ..absBounds = const HeapRect(top: 16, left: 16, bottom: 104, right: 144)
        ..structRgb = rgb;
      return ViDiagram(sectionTag: 'BDHb', objects: [root, loop]);
    }

    ViDiagram decorationDiagram({int? rgb}) {
      final root = ViHeapObject(oid: 1, kind: 0x7e, offset: 0)
        ..category = ViObjectKind.structure
        ..absBounds = const HeapRect(top: 0, left: 0, bottom: 80, right: 120);
      final deco = ViHeapObject(oid: 2, kind: 0x15, offset: 0)
        ..parentOid = 1
        ..category = ViObjectKind.decoration
        ..absBounds = const HeapRect(top: 20, left: 20, bottom: 60, right: 100)
        ..bgRgb = rgb;
      return ViDiagram(sectionTag: 'BDHb', objects: [root, deco]);
    }

    final colourCases = <(String, int, ViDiagram Function({int? rgb}))>[
      ('a caption inks fgRgb', 0x1040E0, captionDiagram),
      ('a loop frame inks structRgb', 0xFFFFCC, framedDiagram),
      ('a decoration inks bgRgb', 0xE01010, decorationDiagram),
    ];

    for (final (what, rgb, build) in colourCases) {
      testWidgets(what, (tester) async {
        Future<Uint32List> packedPixels(BdRaster raster) async {
          final bytes = (await raster.image.toByteData())!.buffer.asUint8List();
          final out = Uint32List(bytes.length >> 2);
          for (var i = 0; i < out.length; i++) {
            final j = i << 2;
            out[i] =
                0xFF000000 |
                (bytes[j] << 16) |
                (bytes[j + 1] << 8) |
                bytes[j + 2];
          }
          return out;
        }

        await tester.runAsync(() async {
          final inked = await rasteriseBlockDiagram(build(rgb: rgb));
          final plain = await rasteriseBlockDiagram(build());
          expect(inked!.content, plain!.content);
          final inkedPixels = await packedPixels(inked);
          final plainPixels = await packedPixels(plain);
          expect(inkedPixels.length, plainPixels.length);
          final want = 0xFF000000 | rgb;
          var changed = 0, changedToWant = 0;
          for (var i = 0; i < inkedPixels.length; i++) {
            if (inkedPixels[i] == plainPixels[i]) continue;
            changed++;
            if (inkedPixels[i] == want) changedToWant++;
          }
          expect(changed, greaterThan(0));
          expect(
            changedToWant,
            greaterThan(0),
            reason: 'no pixel changed to 0x${want.toRadixString(16)}',
          );
          expect(
            plainPixels.contains(want),
            isFalse,
            reason:
                '0x${want.toRadixString(16)} already inked without the '
                'decoded field',
          );
        });
      });
    }
  });

  group('dataflow wire rendering', () {
    ViDiagram wireDiagram({bool midNode = false}) {
      final root = ViHeapObject(oid: 1, kind: 0x7e, offset: 0)
        ..category = ViObjectKind.structure
        ..absBounds = const HeapRect(top: 0, left: 0, bottom: 160, right: 420);
      final a = ViHeapObject(oid: 2, kind: 0x2f, offset: 0)
        ..parentOid = 1
        ..category = ViObjectKind.node
        ..absBounds = const HeapRect(
          top: 100,
          left: 20,
          bottom: 140,
          right: 60,
        );
      final b = ViHeapObject(oid: 3, kind: 0x2f, offset: 0)
        ..parentOid = 1
        ..category = ViObjectKind.node
        ..absBounds = const HeapRect(
          top: 100,
          left: 360,
          bottom: 140,
          right: 400,
        );
      final signal = ViHeapObject(oid: 4, kind: 0x17, offset: 0)..parentOid = 1;
      signal.refs
        ..add(2)
        ..add(3);
      final objects = <ViHeapObject>[root, a, b];
      if (midNode) {
        objects.add(
          ViHeapObject(oid: 5, kind: 0x2f, offset: 0)
            ..parentOid = 1
            ..category = ViObjectKind.node
            ..absBounds = const HeapRect(
              top: 100,
              left: 180,
              bottom: 140,
              right: 240,
            ),
        );
      }
      objects.add(signal);
      return ViDiagram(sectionTag: 'BDHb', objects: objects);
    }

    ViWire straightWire() => ViWire(
      signalOid: 4,
      endpointOids: const [2, 3],
      endpointAnchors: const [
        HeapRect(top: 100, left: 20, bottom: 140, right: 60),
        HeapRect(top: 100, left: 360, bottom: 140, right: 400),
      ],
      routePoints: const [(x: 60, y: 120), (x: 360, y: 120)],
      routePointsFidelity: WireRouteFidelity.walked,
    );

    test('a diagram exposes one ViWire with two resolved endpoint anchors', () {
      final wires = wireDiagram().wires;
      expect(wires.length, 1);
      expect(wires.single.endpointAnchors.whereType<HeapRect>().length, 2);
    });

    testWidgets('a wire changes the render (vs the same diagram wire-free)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final diagram = wireDiagram();
        final withWire = await rasteriseBlockDiagram(
          diagram,
          wires: [straightWire()],
        );
        final wireFree = await rasteriseBlockDiagram(diagram, wires: const []);
        final cmp = await compareToReference(withWire!.image, wireFree!.image);
        expect(cmp.comparison.meanAbsDiff, greaterThan(0));
      });
    });

    testWidgets('wires paint under nodes (a node covers a wire it crosses)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        int centrePixel(BdRaster raster) {
          final px = ((210 - raster.content.left) * raster.scale).round();
          final py = ((120 - raster.content.top) * raster.scale).round();
          return (py * raster.image.width + px) * 4;
        }

        final withNode = await rasteriseBlockDiagram(
          wireDiagram(midNode: true),
          wires: [straightWire()],
        );
        final withoutNode = await rasteriseBlockDiagram(
          wireDiagram(),
          wires: [straightWire()],
        );
        expect(withNode!.content, withoutNode!.content);

        final nodeBytes = (await withNode.image.toByteData())!.buffer
            .asUint8List();
        final wireBytes = (await withoutNode.image.toByteData())!.buffer
            .asUint8List();
        final i = centrePixel(withNode);
        expect(nodeBytes[i], greaterThan(150));
        expect(wireBytes[i], lessThan(120));
      });
    });

    test('bdWireColor stays neutral without a typed-terminal anchor', () {
      final wire = wireDiagram().wires.single;
      expect(bdWireColor(wire, const {}), kBdWireColor);
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
      expect(result.comparison.meanAbsDiff, 0);
      expect(result.comparison.diffFraction, 0);
    });
  });

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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BdOracleView(diagram: _synthDiagram())),
      ),
    );
    await settleOracle(tester, find.text('Rendered (clean-room)'));
    expect(tester.takeException(), isNull);
    expect(find.text('Rendered (clean-room)'), findsOneWidget);
    expect(find.text('Reference'), findsNothing);

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
    expect(find.textContaining('mean abs'), findsOneWidget);
    expect(find.textContaining('Structural'), findsOneWidget);
  });

  group('LabVIEW block-diagram styling', () {
    test(
      'canvas is near-white and the grid dot stays within match threshold',
      () {
        expect(kBdCanvas, const Color(0xFFFFFFFF));
        expect(kBdGridDot.a * 255, lessThan(16));
      },
    );

    test('subVI-call node codes are the caption-bearing call classes', () {
      expect(kSubViCallNodeCodes, contains(0x31));
      expect(kSubViCallNodeCodes, contains(0xc5));
      expect(kSubViCallNodeCodes.contains(0x2f), isFalse);
    });

    test('label-part classes are the free-text sub-parts', () {
      expect(
        kBdTextLabelClasses,
        containsAll(<HeapObjectClass>[
          HeapObjectClass.controlLabel,
          HeapObjectClass.bdSelectorLabel,
        ]),
      );
    });

    testWidgets('renders a subVI-call node and a label part without error', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final diagram = modelFromRecords(<int>[
          ...open(0x7e, 1),
          ...bounds(0, 0, 300, 200),
          ...open(0x31, 2, tag: 0x1b),
          ...bounds(40, 40, 72, 72),
          ...caption('Do Thing.vi'),
          ...close(0x1b),
          ...open(0x0a, 3, tag: 0x1c),
          ...bounds(40, 20, 130, 37),
          ...caption('Do Thing.vi'),
          ...close(0x1c),
          ...close(),
        ]).blockDiagrams.first;
        final raster = await rasteriseBlockDiagram(diagram);
        expect(raster, isNotNull);
        expect((await imageToPng(raster!.image)).length, greaterThan(0));
      });
    });
  });

  test('synthetic diagram objects fall within the content rect', () {
    final diagram = _synthDiagram();
    final drawable = bdDrawableObjects(diagram);
    expect(drawable, isNotEmpty);
    final content = bdContentRect(drawable, includeWires: false);
    expect(_allWithin(drawable, content), isTrue);
    final loop = diagram.byId[2]!;
    final members = nodesWithin(loop, drawable);
    expect(members.map((m) => m.oid), contains(3));
  });

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

  testWidgets('a recovered constant literal renders (vs a blank plate)', (
    tester,
  ) async {
    ViDiagram build(String? literal) {
      final root = ViHeapObject(oid: 1, kind: 0x7e, offset: 0)
        ..category = ViObjectKind.structure
        ..absBounds = const HeapRect(top: 0, left: 0, bottom: 80, right: 220);
      final constObj = ViHeapObject(oid: 2, kind: 0x51, offset: 0)
        ..parentOid = 1
        ..category = ViObjectKind.terminal
        ..absBounds = const HeapRect(top: 24, left: 24, bottom: 44, right: 150)
        ..constText = literal;
      return ViDiagram(sectionTag: 'BDHb', objects: [root, constObj]);
    }

    await tester.runAsync(() async {
      final withLiteral = await rasteriseBlockDiagram(build('report.txt'));
      final withoutLiteral = await rasteriseBlockDiagram(build(null));
      final cmp = await compareToReference(
        withLiteral!.image,
        withoutLiteral!.image,
      );
      expect(cmp.comparison.meanAbsDiff, greaterThan(0));
    });
  });

  group('subVI icon rendering', () {
    test('subViWantedNames picks subVI-call node filenames only', () {
      final call = ViHeapObject(oid: 5, kind: 0x31, offset: 0)
        ..category = ViObjectKind.node
        ..label = 'Define Test.vi';
      final another = ViHeapObject(oid: 6, kind: 0x31, offset: 0)
        ..category = ViObjectKind.node
        ..label = 'Not In Corpus.vi';
      final primitive = ViHeapObject(oid: 7, kind: 0x2f, offset: 0)
        ..category = ViObjectKind.node
        ..label = 'Add';
      final diagram = ViDiagram(
        sectionTag: 'BDHb',
        objects: [call, another, primitive],
      );
      expect(subViWantedNames(diagram), {'Define Test.vi', 'Not In Corpus.vi'});
    });

    testWidgets('rasterising with subVI icons stamps the node', (tester) async {
      final corpus = _corpusDir();
      if (corpus == null) return;
      final target = File(
        '${corpus.path}/vipm-io_caraya/vipm-io-caraya-ca35333/'
        'src/classes/Test/Define Test.vi',
      );
      if (!target.existsSync()) return;

      final call = ViHeapObject(oid: 5, kind: 0x31, offset: 0)
        ..category = ViObjectKind.node
        ..label = 'Define Test.vi'
        ..absBounds = const HeapRect(top: 20, left: 20, bottom: 52, right: 52);
      final diagram = ViDiagram(sectionTag: 'BDHb', objects: [call]);
      final icon = decodeViFileIcon(target.path);
      expect(icon, isNotNull);
      final icons = {5: icon!};

      await tester.runAsync(() async {
        final iconed = await rasteriseBlockDiagram(diagram, subViIcons: icons);
        final plain = await rasteriseBlockDiagram(diagram);
        expect(iconed, isNotNull);
        final cmp = await compareToReference(iconed!.image, plain!.image);
        expect(cmp.comparison.meanAbsDiff, greaterThan(0));
      });
    });
  });
}
