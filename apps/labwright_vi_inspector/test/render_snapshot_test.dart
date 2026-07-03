@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

/// Renders real corpus VIs through [ViDiagramView] (block diagram + front
/// panel, both modes) and writes the pixels to PNG files under
/// `build/render_snapshots/`, so the rendering can be *looked at* — the only
/// honest check of visual fidelity. Skips when the corpus is not fetched.
///
/// Run: `flutter test test/render_snapshot_test.dart`
Directory? _corpusDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory(
        '${dir.path}/packages/labwright_rsrc_parse/corpus/vi');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

const _sampleVis = [
  'smithed_vicompare/smithed-vicompare-5bb0d48/Trunk/constants/required keys.vi',
  'NEVSTOP-LAB_Communicable-State-Machine/NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/src/_TEST/test message before initialize.vi',
];

/// Loads a real font so snapshot text is legible (the test default renders
/// every glyph as a solid box). Uses the Roboto shipped in the Flutter SDK.
Future<void> _loadRealFont() async {
  final sdkFont = File(
      '${Platform.environment['FLUTTER_ROOT'] ?? '/home/carson/develop/flutter'}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
  if (!sdkFont.existsSync()) return;
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(sdkFont.readAsBytesSync().buffer.asByteData()));
  await loader.load();
}

void main() {
  final corpus = _corpusDir();
  if (corpus == null) {
    test('render snapshots (skipped: corpus not fetched)', () {}, skip: true);
    return;
  }
  final outDir = Directory('build/render_snapshots')..createSync(recursive: true);

  for (final rel in _sampleVis) {
    final file = File('${corpus.path}/$rel');
    if (!file.existsSync()) continue;
    final shortName = rel.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

    testWidgets('render $shortName', (tester) async {
      await _loadRealFont();
      final model = buildViModel(file.readAsBytesSync());
      await tester.binding.setSurfaceSize(const Size(1400, 900));

      Future<void> snap(List<ViDiagram> diagrams, String label,
          {bool isFrontPanel = false}) async {
        final key = GlobalKey();
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ViDiagramView(diagrams: diagrams, isFrontPanel: isFrontPanel),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final path = '${outDir.path}/$shortName.$label.png';
        File(path).writeAsBytesSync(png!.buffer.asUint8List());
        // ignore: avoid_print
        print('wrote $path');
      }

      if (model.blockDiagrams.any((d) => d.objects.isNotEmpty)) {
        await snap(model.blockDiagrams, 'bd');
      }
      if (model.frontPanelDiagrams.any((d) => d.objects.isNotEmpty)) {
        await snap(model.frontPanelDiagrams, 'fp', isFrontPanel: true);
      }
    });
  }
}
