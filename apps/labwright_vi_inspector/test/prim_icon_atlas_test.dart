import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/generated/prim_icon_atlas.dart';
import 'package:labwright_vi_inspector/src/prim_icon_catalog.dart';

Future<Uint8List> _pixels(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

void main() {
  testWidgets(
    'the raised atlas carries every icon pixel-exact, ringed by its own edge',
    (tester) async {
      await tester.runAsync(() async {
        final icons = loadPrimIcons();
        final wanted = {
          for (final e in kPrimIconAtlas)
            if (kPrimIconStatus[e.key] != PrimIconStatus.rejected)
              parsePrimIconName(e.key),
        }.length;
        expect(icons.length, wanted);
        expect(primIconsGrey.length, wanted);
        final sheets = {
          for (final art in icons.values) art.sheet,
          for (final art in primIconsGrey.values) art.sheet,
        };
        expect(sheets.length, 2);
        final sheetPixels = {
          for (final sheet in sheets) sheet: await _pixels(sheet),
        };
        const sheetWidth = kPrimIconAtlasWidth;
        for (final arts in [icons, primIconsGrey]) {
          for (final art in arts.values) {
            final sheet = sheetPixels[art.sheet]!;
            final left = art.src.left.toInt(), top = art.src.top.toInt();
            for (var y = -1; y <= art.height; y++) {
              for (var x = -1; x <= art.width; x++) {
                final ix = x.clamp(0, art.width - 1),
                    iy = y.clamp(0, art.height - 1);
                final from = (iy * art.width + ix) * 4;
                final at = ((top + y) * sheetWidth + left + x) * 4;
                expect(
                  sheet.sublist(at, at + 4),
                  art.rgba.sublist(from, from + 4),
                  reason: 'sheet pixel ($x, $y) of icon ${art.src}',
                );
              }
            }
            for (var i = 0; i < art.alpha.length; i++) {
              expect(art.alpha[i], art.rgba[i * 4 + 3]);
              expect(art.alpha[i] == 0 || art.alpha[i] == 255, isTrue);
            }
          }
        }
      });
    },
  );
}
