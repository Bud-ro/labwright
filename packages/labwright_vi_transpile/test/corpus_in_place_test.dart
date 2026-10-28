@Tags(['corpus'])
library;

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

LvViUnit _corpusUnit(String fileName) {
  final file = corpusFiles(corpusVi, '.vi').firstWhere((file) => file.uri.pathSegments.last == fileName);
  return LvViUnit.fromSections(decodeSections(file.readAsBytesSync()), fileName: fileName, path: file.path)!;
}

Iterable<LvStructUnit> _structures(LvRegion region) sync* {
  for (final unit in region.units) {
    if (unit is! LvStructUnit) continue;
    yield unit;
    for (final frame in unit.frames) {
      yield* _structures(frame);
    }
  }
}

void main() {
  test('a Data Value Reference pair reads its reference and writes it back, its error terminals apart', () {
    final unit = _corpusUnit('CSMKVMap-Preview.vi');
    final built = buildLvDataflow(unit.diagram, pool: unit.pool);
    expect(built.refusal, isNull, reason: '${built.refusal}');
    final pairs = [
      for (final structure in _structures(built.dataflow!.root)) ...structure.inPlaceDataValueRefPairs,
    ];
    expect(pairs, isNotEmpty);
    for (final pair in pairs) {
      expect(pair.referenceOut, isNotNull);
      expect({pair.referenceIn, pair.referenceOut, pair.errorOut}, hasLength(3));
      expect({pair.elementOut, pair.elementIn, pair.readErrorOut, pair.writeErrorIn}, hasLength(4));
    }
  });
}
