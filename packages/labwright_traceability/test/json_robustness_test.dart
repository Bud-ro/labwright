import 'dart:math';

import 'package:labwright_traceability/labwright_traceability.dart';
import 'package:test/test.dart';

final _specs = parseRequirements([
  {'id': 'REQ-1', 'hash': 'h1'},
]);

void main() {
  test('tolerates malformed record JSON without throwing', () {
    final malformed = <Map<String, Object?>>[
      {}, // empty
      {'phases': 'not a list'},
      {'phases': [42, 'x', null]}, // non-map phases
      {
        'phases': [
          {'name': 'p', 'requirements': 'nope'}, // reqs not a list
        ],
      },
      {
        'phases': [
          {
            'name': 'p',
            'outcome': 123, // wrong-typed outcome
            'requirements': [42, null, <String, Object?>{}], // bad refs + ref missing id
            'measurements': 'nope',
          },
        ],
      },
      {
        'phases': [
          {
            'measurements': [
              {'name': 'm', 'requirements': [{'id': 'REQ-1', 'hash': 'h1'}]},
              'not a map',
            ],
          },
        ],
      },
    ];
    for (final rec in malformed) {
      expect(() => buildTraceMatrixFromRecordJson(_specs, [rec]), returnsNormally);
    }
    // the last well-formed measurement ref is still picked up
    final m = buildTraceMatrixFromRecordJson(_specs, [malformed.last]);
    expect(m.entries.single.isCovered, isTrue);
  });

  test('random nested junk never throws', () {
    final rng = Random(5);
    Object? junk(int depth) {
      if (depth <= 0) return [null, 1, 'x', true, 1.5][rng.nextInt(5)];
      switch (rng.nextInt(4)) {
        case 0:
          return [for (var i = 0; i < rng.nextInt(4); i++) junk(depth - 1)];
        case 1:
          return {for (var i = 0; i < rng.nextInt(4); i++) 'k$i': junk(depth - 1)};
        case 2:
          return rng.nextInt(1000);
        default:
          return 'str${rng.nextInt(99)}';
      }
    }

    for (var i = 0; i < 2000; i++) {
      final rec = <String, Object?>{
        'testName': junk(1),
        'phases': junk(3),
      };
      expect(() => buildTraceMatrixFromRecordJson(_specs, [rec]), returnsNormally);
    }
  });
}
