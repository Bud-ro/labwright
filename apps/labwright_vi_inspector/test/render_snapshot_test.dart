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
      '${dir.path}/packages/labwright_rsrc_parse/corpus/vi',
    );
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

const _curatedVis = [
  'smithed_vicompare/smithed-vicompare-5bb0d48/Trunk/constants/required keys.vi',
  'NEVSTOP-LAB_Communicable-State-Machine/NEVSTOP-LAB-Communicable-State-Machine-afe7d4d/src/_TEST/test message before initialize.vi',
];

/// Sweep mode renders ~100 diverse corpus VIs instead of the curated two:
/// `flutter test test/render_snapshot_test.dart --dart-define=RENDER_SWEEP=true`
/// Diversity = round-robin across corpus sources with a per-source size
/// spread, deterministically (sorted paths, evenly-spaced picks).
const bool _sweep = bool.fromEnvironment('RENDER_SWEEP');
const int _sweepTarget = 100;

List<String> _diverseSample(Directory corpus) {
  final bySource = <String, List<File>>{};
  for (final entry in corpus.listSync().whereType<Directory>()) {
    final files =
        entry
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.vi'))
            .toList()
          ..sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));
    if (files.isNotEmpty) bySource[entry.path.split('/').last] = files;
  }
  final perSource = (_sweepTarget / bySource.length).ceil();
  final picks = <String>[];
  for (final files in bySource.values) {
    // evenly spaced through the size-sorted list: smallest, spread, largest
    for (var i = 0; i < perSource && picks.length < _sweepTarget; i++) {
      final index = files.length <= perSource
          ? i
          : (i * (files.length - 1)) ~/ (perSource - 1).clamp(1, 1 << 30);
      if (index >= files.length) break;
      picks.add(files[index].path.substring(corpus.path.length + 1));
    }
  }
  return picks;
}

/// Loads a real font so snapshot text is legible (the test default renders

/// every glyph as a solid box). Uses the Roboto shipped in the Flutter SDK.
Future<void> _loadRealFont() async {
  final sdkFont = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? '/home/carson/develop/flutter'}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
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
  final outDir = Directory('build/render_snapshots')
    ..createSync(recursive: true);

  final sample = _sweep ? _diverseSample(corpus) : _curatedVis;
  // ignore: avoid_print
  print('render snapshots: ${sample.length} VIs (sweep=$_sweep)');
  for (final rel in sample) {
    final file = File('${corpus.path}/$rel');
    if (!file.existsSync()) continue;
    final shortName = rel
        .split('/')
        .last
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

    Future<void> snapTest(String label, {required bool isFrontPanel}) async {
      testWidgets('render $shortName $label', (tester) async {
        final clock = Stopwatch()..start();
        int lap() {
          final ms = clock.elapsedMilliseconds;
          clock.reset();
          return ms;
        }

        await _loadRealFont();
        final fontMs = lap();
        final ViModel model;
        try {
          model = buildViModel(file.readAsBytesSync());
        } on ViFormatException {
          // Not a real VI (e.g. the G-CLI test stub) — nothing to render.
          return;
        }
        final modelMs = lap();
        final diagrams = isFrontPanel
            ? model.frontPanelDiagrams
            : model.blockDiagrams;
        if (!diagrams.any((d) => d.objects.isNotEmpty)) return;
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: ViDiagramView(
                  diagrams: diagrams,
                  isFrontPanel: isFrontPanel,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        final pumpMs = lap();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        // toImage/toByteData perform real async work; run them outside the
        // fake-async test zone or they can never complete.
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final rasterMs = lap();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final encodeMs = lap();
          final path = '${outDir.path}/$shortName.$label.png';
          File(path).writeAsBytesSync(png!.buffer.asUint8List());
          // ignore: avoid_print
          print(
            'wrote $path  font=${fontMs}ms model=${modelMs}ms '
            'pump=${pumpMs}ms raster=${rasterMs}ms encode=${encodeMs}ms',
          );
        });
        // Unmount so no timers/animations outlive the test.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      });
    }

    snapTest('bd', isFrontPanel: false);
    snapTest('fp', isFrontPanel: true);
  }
}
