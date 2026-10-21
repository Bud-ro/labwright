import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';

import 'util.dart';

/// A diagram holding one primitive and one label attached to it by an attachment glyph.
ViModel attachedLabelModel({
  required (int, int, int, int) label,
  required (int, int, int, int) target,
}) => modelFromRecords(<int>[
  ...open(0x7e, 1),
  ...bounds(0, 0, 400, 400),
  ...open(0x2f, 2, tag: 0x1a),
  ...bounds(target.$1, target.$2, target.$3, target.$4),
  ...close(0x1a),
  ...open(0x0a, 3, tag: 0x1a),
  ...bounds(label.$1, label.$2, label.$3, label.$4),
  ...encodeHeapRef(0x16, 0x8a, 4),
  ...open(0x177, 4, tag: 0x1b),
  ...bounds(0, 0, 9, 9),
  ...encodeHeapRef(0x16, 0x89, 2),
  ...close(0x1b),
  ...close(0x1a),
  ...close(),
]);

Future<(Uint8List, int, int, int)> render(ViModel model) async {
  final bd = bestBlockDiagram(model)!;
  final raster = (await rasteriseBlockDiagram(
    bd,
    scale: 1.0,
    margin: 2,
    drawable: bdDrawableObjects(bd),
  ))!;
  final px = (await raster.image.toByteData())!.buffer.asUint8List();
  return (
    px,
    raster.image.width,
    raster.content.left.round(),
    raster.content.top.round(),
  );
}

void main() {
  testWidgets(
    'an aligned attachment arrow is a 2 px shaft with a notched head',
    (tester) async {
      await tester.runAsync(() async {
        final (px, width, ox, oy) = await render(
          attachedLabelModel(
            label: (48, 20, 65, 120),
            target: (40, 200, 72, 232),
          ),
        );
        int red(int x, int y) => px[((y - oy) * width + (x - ox)) * 4];

        expect(red(150, 56), lessThan(40), reason: 'shaft row is black');
        expect(red(150, 55), inInclusiveRange(90, 170), reason: 'shaft edge');
        expect(red(150, 57), inInclusiveRange(90, 170), reason: 'shaft edge');
        expect(red(150, 54), greaterThan(240), reason: 'shaft is 2 px wide');
        expect(red(150, 58), greaterThan(240), reason: 'shaft is 2 px wide');
        expect(red(121, 56), lessThan(40), reason: 'shaft starts at the label');
        expect(
          red(119, 56),
          greaterThan(240),
          reason: 'the label edge is clear',
        );
        expect(
          red(188, 56),
          lessThan(40),
          reason: 'shaft ends 11 px before the tip',
        );
        expect(red(190, 56), greaterThan(240), reason: 'gap before the notch');
        expect(red(195, 56), lessThan(40), reason: 'head interior');
        expect(red(199, 56), inInclusiveRange(60, 130), reason: 'tip pixel');
        expect(red(198, 54), greaterThan(240), reason: 'head tapers to the tip');
        expect(red(189, 53), lessThan(200), reason: 'upper barb');
        expect(red(189, 59), lessThan(200), reason: 'lower barb');
        expect(red(189, 52), greaterThan(240), reason: 'head is 8 px wide');
        expect(red(189, 60), greaterThan(240), reason: 'head is 8 px wide');
        expect(red(195, 53), greaterThan(240), reason: 'head tapers');
      });
    },
  );

  testWidgets(
    'a slanted attachment arrow aims from the label edge at the target centre',
    (tester) async {
      await tester.runAsync(() async {
        final (px, width, ox, oy) = await render(
          attachedLabelModel(
            label: (20, 20, 52, 120),
            target: (150, 200, 182, 232),
          ),
        );
        int red(int x, int y) => px[((y - oy) * width + (x - ox)) * 4];

        expect(red(197, 148), lessThan(60), reason: 'head at the entry pixel');
        expect(
          red(139, 98),
          lessThan(100),
          reason: 'shaft on the tail-to-centre line',
        );
        expect(red(135, 101), greaterThan(240), reason: 'shaft is thin');
        expect(red(143, 95), greaterThan(240), reason: 'shaft is thin');
        expect(
          red(89, 53),
          lessThan(120),
          reason: 'shaft starts where it leaves the label',
        );
      });
    },
  );
}
