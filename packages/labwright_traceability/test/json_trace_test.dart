import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_traceability/labwright_traceability.dart';
import 'package:test/test.dart';

final _specs = parseRequirements([
  {'id': 'REQ-1', 'hash': 'h1'},
  {'id': 'REQ-2', 'hash': 'h2'},
  {'id': 'REQ-3', 'hash': 'h3'},
]);

Future<Map<String, Object?>> _recordJson({required String railHash}) async {
  final rec = await Test('t', [
    Phase('rail', (ctx) async {
      ctx
          .measure<num>('v', validators: [Validators.inRange(0, 5)], requirements: [RequirementRef('REQ-1', hash: railHash)])
          .value = 3.3;
    }),
    Phase('serial', (ctx) async {
      ctx.measure<String>('sn', requirements: [const RequirementRef('REQ-2', hash: 'h2')]).value = 'SN1';
    }),
  ]).run(dutId: 'D');
  return rec.toJson();
}

void main() {
  test('builds the same coverage from record.json as from objects', () async {
    final rec = await Test('t', [
      Phase('rail', (ctx) async {
        ctx
            .measure<num>('v', validators: [Validators.inRange(0, 5)], requirements: [const RequirementRef('REQ-1', hash: 'h1')])
            .value = 3.3;
      }),
    ]).run(dutId: 'D');

    final fromObjects = buildTraceMatrix(_specs, [rec]);
    final fromJson = buildTraceMatrixFromRecordJson(_specs, [rec.toJson()]);

    expect(fromJson.coverage, fromObjects.coverage);
    expect(fromJson.uncovered.map((e) => e.spec.id).toSet(), fromObjects.uncovered.map((e) => e.spec.id).toSet());
    expect(fromJson.entries.firstWhere((e) => e.spec.id == 'REQ-1').outcome, Outcome.pass);
  });

  test('covers from JSON; flags the uncovered requirement', () async {
    final m = buildTraceMatrixFromRecordJson(_specs, [await _recordJson(railHash: 'h1')]);
    expect(m.entries.firstWhere((e) => e.spec.id == 'REQ-1').isCovered, isTrue);
    expect(m.entries.firstWhere((e) => e.spec.id == 'REQ-2').isCovered, isTrue);
    expect(m.uncovered.map((e) => e.spec.id), ['REQ-3']);
    expect(m.ok(), isFalse); // REQ-3 uncovered
  });

  test('detects hash drift from JSON', () async {
    final m = buildTraceMatrixFromRecordJson(_specs, [await _recordJson(railHash: 'STALE')]);
    expect(m.drifted.map((e) => e.spec.id), contains('REQ-1'));
    expect(m.ok(minCoverage: 0), isFalse);
  });
}
