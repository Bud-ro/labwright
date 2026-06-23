import 'package:labwright_traceability/labwright_traceability.dart';
import 'package:test/test.dart';

void main() {
  test('empty requirements + empty records is a vacuously-ok matrix', () {
    final m = buildTraceMatrixFromRecordJson(const {}, const []);
    expect(m.entries, isEmpty);
    expect(m.coverage, 1.0);
    expect(m.ok(), isTrue);
  });

  test('requirements but no records => all uncovered', () {
    final specs = parseRequirements([
      {'id': 'REQ-1', 'hash': 'h1'},
    ]);
    final m = buildTraceMatrixFromRecordJson(specs, const []);
    expect(m.uncovered.map((e) => e.spec.id), ['REQ-1']);
    expect(m.ok(), isFalse);
  });
}
