import 'package:labwright_core/labwright_core.dart';
import 'package:labwright_example/labwright_example.dart';
import 'package:labwright_traceability/labwright_traceability.dart';
import 'package:test/test.dart';

void main() {
  test('a healthy DUT passes and covers every requirement', () async {
    final rec = await psuTest(demoPsuDaq()).run(dutId: 'PSU-001');
    expect(rec.outcome, Outcome.pass);

    final matrix = buildTraceMatrix(psuRequirements(), [rec]);
    expect(matrix.uncovered, isEmpty);
    expect(matrix.drifted, isEmpty);
    expect(matrix.ok(), isTrue);
  });

  test('a 5V brownout fails the 5V rail phase and the test', () async {
    final rec = await psuTest(demoPsuDaq(faultyRail5v: true)).run(dutId: 'PSU-002');
    expect(rec.outcome, Outcome.fail);
    expect(rec.phases.firstWhere((p) => p.name == 'rail 5v').outcome, Outcome.fail);
    // Coverage is unaffected by outcome: the failing requirement is still traced.
    final matrix = buildTraceMatrix(psuRequirements(), [rec]);
    expect(matrix.entries.firstWhere((e) => e.spec.id == 'REQ-PWR-002').outcome, Outcome.fail);
  });

  test('a malformed serial fails the ID requirement', () async {
    final rec = await psuTest(demoPsuDaq(), serial: 'BADSERIAL').run(dutId: 'PSU-003');
    expect(rec.outcome, Outcome.fail);
  });
}
