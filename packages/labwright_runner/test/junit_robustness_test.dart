import 'dart:math';

import 'package:labwright_runner/labwright_runner.dart';
import 'package:test/test.dart';

void main() {
  test('recordJsonToJUnit tolerates malformed records without throwing', () {
    final malformed = <Map<String, Object?>>[
      {}, // empty
      {'phases': 'not a list'},
      {'phases': [42, 'x', null]}, // non-map phases
      {
        'testName': 123, // wrong-typed name
        'phases': [
          {'name': null, 'outcome': 99, 'measurements': 'nope'},
        ],
      },
      {
        'phases': [
          {
            'name': 'p',
            'outcome': 'fail',
            'measurements': [
              {'name': 'm', 'outcome': 'fail', 'value': null},
              'not a map',
              42,
            ],
          },
        ],
      },
    ];
    for (final rec in malformed) {
      expect(() => recordJsonToJUnit(rec), returnsNormally);
      expect(recordJsonToJUnit(rec), contains('<testsuite'));
      expect(() => recordsToJUnitSuites([rec]), returnsNormally);
    }
  });

  test('random nested junk never throws and stays rooted', () {
    final rng = Random(7);
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
      final rec = <String, Object?>{'testName': junk(1), 'dutId': junk(1), 'phases': junk(3)};
      expect(() => recordJsonToJUnit(rec), returnsNormally);
      expect(() => recordsToJUnitSuites([rec, rec]), returnsNormally);
      expect(recordsToJUnitSuites([rec]), contains('<testsuites'));
    }
  });
}
