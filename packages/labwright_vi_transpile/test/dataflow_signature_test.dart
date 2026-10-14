@Tags(['corpus'])
library;

import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

import 'snippets.dart';

void main() {
  test('a signature names every unit, port and edge without object ids, and is stable', () {
    final vi = snippetUnit('crc8');
    final flow = buildLvDataflow(vi.diagram, pool: vi.pool).dataflow!;
    final signature = lvDataflowSignature(flow);
    expect(signature, lvDataflowSignature(buildLvDataflow(vi.diagram, pool: vi.pool).dataflow!));
    expect(signature, isNot(contains('u0.in0 ->')));
    expect(signature, contains('prim exclusiveOr'));
    expect(signature, contains('forLoop'));
    expect(signature, contains(' -> '));
    expect(signature.split('\n').where((l) => l.contains('control ')).length, greaterThan(1));
  });
}
