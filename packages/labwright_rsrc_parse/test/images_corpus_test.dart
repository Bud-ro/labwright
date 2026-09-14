@Tags(['corpus'])
library;

import 'dart:io';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

void main() {
  test('a PICT picture yields its QuickTime raster', () {
    final file = File(
      '${corpusViDir.path}/tuftsBaxter_ROS-for-LabVIEW-Software/'
      'tuftsBaxter-ROS-for-LabVIEW-Software-cef95f1/ROS for LabVIEW Software/PlayArea/Controls/OriginalTest.vi',
    );
    final images = viImagesOf(decodeSections(file.readAsBytesSync()));
    final raster = images.rasters.single.raster;
    expect((images.rasters.single.tag, raster.width, raster.height, raster.depth), ('PICT', 411, 489, 24));
    expect(raster.pixels.length, 411 * 489 * 3);
  });
}
