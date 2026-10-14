@Tags(['corpus'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_text/labwright_vi_text.dart';

import 'util.dart';

Future<Uint8List> _rgba(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.rawRgba,
))!.buffer.asUint8List();

void main() {
  testWidgets(
    'a VI rebuilt from its text form draws the same block diagram, pixel for pixel',
    (tester) async {
      await loadRealTextFont();
      await tester.runAsync(() async {
        final icons = loadPrimIcons();
        for (final name in ['crc8.png', 'fg.png', 'MD5.png']) {
          final original = extractSnippetVi(
            snippetPng(name).readAsBytesSync(),
          )!;
          final rebuilt = viSpecOf(original).encode();
          final rasters = <BdRaster>[];
          for (final bytes in [original, rebuilt]) {
            final diagram = bestBlockDiagram(buildViModel(bytes))!;
            rasters.add(
              (await rasteriseBlockDiagram(
                diagram,
                primIcons: icons,
                scale: 1.0,
                margin: 2,
              ))!,
            );
          }
          final [a, b] = rasters;
          expect(
            (b.image.width, b.image.height),
            (a.image.width, a.image.height),
            reason: name,
          );
          final compared = compareRgba(
            await _rgba(a.image),
            await _rgba(b.image),
            a.image.width,
            a.image.height,
          );
          expect(compared.diffFraction, 0, reason: name);
        }
      });
    },
  );
}
