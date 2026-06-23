import 'package:labwright_core/labwright_core.dart';
import 'package:test/test.dart';

void main() {
  test('a zero-phase test passes with no phase records', () async {
    final rec = await Test('empty', const []).run(dutId: 'D');
    expect(rec.outcome, Outcome.pass);
    expect(rec.phases, isEmpty);
  });

  test('a phase with zero measurements passes', () async {
    final rec = await Test('t', [Phase('noop', (ctx) async {})]).run(dutId: 'D');
    expect(rec.outcome, Outcome.pass);
    expect(rec.phases.single.outcome, Outcome.pass);
    expect(rec.phases.single.measurements, isEmpty);
  });

  test('requirement-ref codec round-trips and is tolerant', () {
    const refs = [RequirementRef('REQ-1', hash: 'h1'), RequirementRef('REQ-2', hash: 'h2')];
    final encoded = encodeRequirementRefs(refs);
    expect(encoded, 'REQ-1@h1; REQ-2@h2');
    final back = decodeRequirementRefs(encoded);
    expect(back.map((r) => r.id), ['REQ-1', 'REQ-2']);
    expect(back.map((r) => r.hash), ['h1', 'h2']);

    // Tolerant of whitespace, empty segments, and a missing @hash.
    final loose = decodeRequirementRefs('  REQ-A@x ;; REQ-B ');
    expect(loose.map((r) => '${r.id}/${r.hash}'), ['REQ-A/x', 'REQ-B/']);
    expect(encodeRequirementRefs(const []), '');
    expect(decodeRequirementRefs(''), isEmpty);
  });
}
