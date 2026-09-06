/// Writes `build/bd_oracle/<name>.{render,reference,diff}.png` for one VI against its reference:
///     flutter test tool/bd_reference_dump.dart \
///       --dart-define=BD_VI=/abs/path/foo.vi \
///       --dart-define=BD_REFERENCE=/abs/path/foo.bd.png
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/bd_oracle.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

const _viPath = String.fromEnvironment('BD_VI');
const _referencePath = String.fromEnvironment('BD_REFERENCE');

void main() {
  final viFile = File(_viPath), referenceFile = File(_referencePath);
  if (_viPath.isEmpty || _referencePath.isEmpty) {
    test(
      'bd reference dump (skipped: BD_VI/BD_REFERENCE unset)',
      () {},
      skip: true,
    );
    return;
  }
  testWidgets('bd reference dump', (tester) async {
    if (!viFile.existsSync()) {
      fail('BD_VI does not exist: ${viFile.path}');
    }
    if (!referenceFile.existsSync()) {
      fail('BD_REFERENCE does not exist: ${referenceFile.path}');
    }
    final model = buildViModel(viFile.readAsBytesSync());
    final diagram = model.blockDiagrams
        .where((d) => d.objects.any((o) => o.absBounds != null))
        .firstOrNull;
    if (diagram == null) {
      fail('no placed block diagram in ${viFile.path}');
    }
    await tester.runAsync(() async {
      final raster = await rasteriseBlockDiagram(diagram);
      final reference = await decodeImage(referenceFile.readAsBytesSync());
      final result = await compareToReference(raster!.image, reference);
      final out = Directory('build/bd_oracle')..createSync(recursive: true);
      final name = viFile.uri.pathSegments.last;
      for (final (label, image) in [
        ('render', result.fitted),
        ('reference', result.reference),
        ('diff', result.diffImage),
      ]) {
        File(
          '${out.path}/$name.$label.png',
        ).writeAsBytesSync(await imageToPng(image));
      }
      // ignore: avoid_print
      print(
        'bd_oracle $name: '
        'meanAbsDiff=${result.comparison.meanAbsDiff.toStringAsFixed(2)} '
        'diffFraction=${(result.comparison.diffFraction * 100).toStringAsFixed(1)}%',
      );
    });
  });
}
