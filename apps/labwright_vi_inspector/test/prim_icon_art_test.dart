import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';
import 'package:labwright_vi_inspector/src/generated/prim_icon_art.dart';
import 'package:labwright_vi_inspector/src/prim_icon_catalog.dart';

void main() {
  testWidgets('every raised icon carries its generated pixels exactly', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final icons = loadPrimIcons();
      final wanted = {
        for (final key in kPrimIconArt.keys)
          if (kPrimIconStatus[key] != PrimIconStatus.rejected)
            parsePrimIconName(key),
      }.length;
      expect(icons.length, wanted);
      expect(primIconsGrey.length, wanted);
      for (final arts in [icons, primIconsGrey]) {
        for (final MapEntry(key: id, value: art) in arts.entries) {
          expect(art.image.width, art.width);
          expect(art.image.height, art.height);
          final raised = (await art.image.toByteData())!.buffer.asUint8List();
          expect(raised, art.rgba, reason: 'icon $id');
          for (var i = 0; i < art.alpha.length; i++) {
            expect(art.alpha[i], art.rgba[i * 4 + 3]);
            expect(art.alpha[i] == 0 || art.alpha[i] == 255, isTrue);
          }
        }
      }
    });
  });
}
