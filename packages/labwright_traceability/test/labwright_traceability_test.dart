import 'dart:convert';

import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_traceability/labwright_traceability.dart';
import 'package:test/test.dart';

final _specs = parseRequirements([
  {'id': 'REQ-1', 'hash': 'h1', 'text': 'rail in range'},
  {'id': 'REQ-2', 'hash': 'h2', 'text': 'serial format'},
  {'id': 'REQ-3', 'hash': 'h3', 'text': 'uncovered one'},
]);

Test _demo({required String railHash}) => Test('rail-test', [
      Phase('rail', (ctx) async {
        ctx
            .measure<num>(
              'v',
              validators: [Validators.inRange(0, 5)],
              requirements: [RequirementRef('REQ-1', hash: railHash)],
            )
            .value = 3.3;
      }),
      Phase('serial', (ctx) async {
        ctx
            .measure<String>('sn', requirements: [const RequirementRef('REQ-2', hash: 'h2')])
            .value = 'SN1';
      }),
    ]);

void main() {
  test('covers requirements, reports outcome and coverage threshold', () async {
    final rec = await _demo(railHash: 'h1').run(dutId: 'D');
    final m = buildTraceMatrix(_specs, [rec]);

    final req1 = m.entries.firstWhere((e) => e.spec.id == 'REQ-1');
    expect(req1.isCovered, isTrue);
    expect(req1.outcome, Outcome.pass);
    expect(req1.hasDrift, isFalse);

    expect(m.uncovered.map((e) => e.spec.id), contains('REQ-3'));
    expect(m.ok(), isFalse); // REQ-3 uncovered -> not full coverage
    expect(m.ok(minCoverage: 0.6), isTrue); // 2/3 covered, no drift
  });

  test('detects hash drift and fails regardless of coverage', () async {
    final rec = await _demo(railHash: 'STALE').run(dutId: 'D');
    final m = buildTraceMatrix(_specs, [rec]);
    expect(m.drifted.map((e) => e.spec.id), contains('REQ-1'));
    expect(m.ok(minCoverage: 0), isFalse);
    expect(traceReport(m), contains('DRIFT'));
  });

  test('flags references to unknown requirement ids', () async {
    final t = Test('x', [
      Phase('p', (ctx) async {
        ctx.measure<num>('v', requirements: [const RequirementRef('REQ-999', hash: 'h')]).value = 1;
      }),
    ]);
    final rec = await t.run(dutId: 'D');
    final m = buildTraceMatrix(_specs, [rec]);
    expect(m.unknownRefs.map((r) => r.requirementId), contains('REQ-999'));
    expect(m.ok(minCoverage: 0), isFalse);
  });

  test('traceMatrixToJson is encodable and mirrors the matrix', () async {
    final rec = await _demo(railHash: 'h1').run(dutId: 'D');
    final m = buildTraceMatrix(_specs, [rec]);
    final json = traceMatrixToJson(m);

    // Encodable with no custom toEncodable.
    expect(() => jsonEncode(json), returnsNormally);

    expect(json['ok'], isFalse); // REQ-3 uncovered
    expect(json['total'], 3);
    expect(json['covered'], 2);

    final reqs = (json['requirements'] as List).cast<Map<String, Object?>>();
    final req1 = reqs.firstWhere((r) => r['id'] == 'REQ-1');
    expect(req1['covered'], isTrue);
    expect(req1['outcome'], 'pass');
    expect(req1['drift'], isFalse);
    expect(req1['text'], 'rail in range');
    final cov = (req1['coverage'] as List).single as Map<String, Object?>;
    expect(cov['where'], 'rail-test/rail/v');
    expect(cov['referencedHash'], 'h1');
    expect(cov['drift'], isFalse);

    final req3 = reqs.firstWhere((r) => r['id'] == 'REQ-3');
    expect(req3['covered'], isFalse);
    expect(req3['outcome'], isNull);
    expect(req3['coverage'] as List, isEmpty);
  });

  test('traceMatrixToJson surfaces drift and unknown refs', () async {
    final rec = await _demo(railHash: 'STALE').run(dutId: 'D');
    final m = buildTraceMatrix(_specs, [rec]);
    final json = traceMatrixToJson(m);
    final req1 = (json['requirements'] as List).cast<Map<String, Object?>>().firstWhere((r) => r['id'] == 'REQ-1');
    expect(req1['drift'], isTrue);
    expect(((req1['coverage'] as List).single as Map)['drift'], isTrue);
  });

  test('parseRequirements handles a map under a list key', () {
    final specs = parseRequirements({
      'requirements': [
        {'id': 'A', 'hash': 'x'},
      ],
    });
    expect(specs['A']!.hash, 'x');
  });

  group('lintRequirements', () {
    test('a clean file produces no issues', () {
      expect(
        lintRequirements([
          {'id': 'REQ-1', 'hash': 'h1'},
          {'id': 'REQ-2', 'hash': 'h2'},
        ]),
        isEmpty,
      );
    });

    test('flags duplicate ids, empty/missing hashes, and bad entries', () {
      final issues = lintRequirements([
        {'id': 'REQ-1', 'hash': 'h1'},
        {'id': 'REQ-1', 'hash': 'h2'}, // duplicate id
        {'id': 'REQ-3', 'hash': ''}, // empty hash
        {'id': 'REQ-4'}, // missing hash
        {'hash': 'h5'}, // missing id
        'not an object', // malformed entry
      ]);
      expect(issues.any((i) => i.contains('duplicate id "REQ-1"')), isTrue);
      expect(issues.any((i) => i.contains('REQ-3') && i.contains('hash')), isTrue);
      expect(issues.any((i) => i.contains('REQ-4') && i.contains('hash')), isTrue);
      expect(issues.any((i) => i.contains('has no "id"')), isTrue);
      expect(issues.any((i) => i.contains('not an object')), isTrue);
    });

    test('non-list/non-map input and empty list are flagged', () {
      expect(lintRequirements(42).single, contains('must be a JSON list or object'));
      expect(lintRequirements(<Object?>[]).single, contains('no requirement entries'));
    });
  });
}
