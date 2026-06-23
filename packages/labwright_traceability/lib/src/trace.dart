import 'package:labwright_core/labwright_core.dart';

import 'requirements.dart';

/// One place a requirement is referenced from: a phase (and optionally a
/// measurement within it), with the outcome and the hash the test pinned.
class CoverageRef {
  const CoverageRef({
    required this.requirementId,
    required this.testName,
    required this.phaseName,
    required this.measurement,
    required this.outcome,
    required this.referencedHash,
  });

  final String requirementId;
  final String testName;
  final String phaseName;
  final String? measurement;
  final Outcome outcome;
  final String referencedHash;
}

/// A requirement plus everything that covers it.
class TraceEntry {
  TraceEntry(this.spec, this.coverage);
  final RequirementSpec spec;
  final List<CoverageRef> coverage;

  bool get isCovered => coverage.isNotEmpty;

  /// Worst outcome across covering refs (error > fail > pass > skip).
  Outcome get outcome => combineOutcomes(coverage.map((c) => c.outcome));

  /// Covering refs whose pinned hash no longer matches the requirement file.
  List<CoverageRef> get drifted => [for (final c in coverage) if (c.referencedHash != spec.hash) c];

  bool get hasDrift => drifted.isNotEmpty;
}

/// The full requirement-to-test mapping for a set of runs.
class TraceMatrix {
  TraceMatrix(this.entries, this.unknownRefs);

  /// One per requirement in the requirements file.
  final List<TraceEntry> entries;

  /// References to requirement ids that aren't in the requirements file.
  final List<CoverageRef> unknownRefs;

  List<TraceEntry> get uncovered => [for (final e in entries) if (!e.isCovered) e];
  List<TraceEntry> get drifted => [for (final e in entries) if (e.hasDrift) e];

  double get coverage =>
      entries.isEmpty ? 1.0 : entries.where((e) => e.isCovered).length / entries.length;

  /// Build passes when there is no hash drift, no unknown references, and
  /// coverage meets [minCoverage] (default: full coverage required).
  bool ok({double minCoverage = 1.0}) =>
      drifted.isEmpty && unknownRefs.isEmpty && coverage >= minCoverage;
}

/// Cross-references [requirements] with the requirement refs carried by [records].
TraceMatrix buildTraceMatrix(Map<String, RequirementSpec> requirements, Iterable<TestRecord> records) {
  final refs = <CoverageRef>[];
  for (final rec in records) {
    for (final p in rec.phases) {
      for (final r in p.requirements) {
        refs.add(CoverageRef(
          requirementId: r.id,
          testName: rec.testName,
          phaseName: p.name,
          measurement: null,
          outcome: p.outcome,
          referencedHash: r.hash,
        ));
      }
      for (final m in p.measurements) {
        for (final r in m.requirements) {
          refs.add(CoverageRef(
            requirementId: r.id,
            testName: rec.testName,
            phaseName: p.name,
            measurement: m.name,
            outcome: m.outcome,
            referencedHash: r.hash,
          ));
        }
      }
    }
  }

  return _matrixFromRefs(requirements, refs);
}

TraceMatrix _matrixFromRefs(Map<String, RequirementSpec> requirements, List<CoverageRef> refs) {
  final byId = <String, List<CoverageRef>>{};
  for (final ref in refs) {
    (byId[ref.requirementId] ??= []).add(ref);
  }
  final entries = [for (final spec in requirements.values) TraceEntry(spec, byId[spec.id] ?? const [])];
  final unknown = [for (final ref in refs) if (!requirements.containsKey(ref.requirementId)) ref];
  return TraceMatrix(entries, unknown);
}

/// A human-readable summary of [matrix]. The pass/fail result honors
/// [minCoverage] (default: full coverage required), matching [TraceMatrix.ok].
String traceReport(TraceMatrix matrix, {double minCoverage = 1.0}) {
  final out = StringBuffer()
    ..writeln('Requirement trace matrix')
    ..writeln('  coverage: ${(matrix.coverage * 100).toStringAsFixed(1)}% '
        '(${matrix.entries.where((e) => e.isCovered).length}/${matrix.entries.length})');

  for (final e in matrix.entries) {
    final status = !e.isCovered ? 'UNCOVERED' : (e.hasDrift ? '${e.outcome.name} DRIFT' : e.outcome.name);
    out.writeln('  ${e.spec.id}: $status');
    for (final c in e.coverage) {
      final where = c.measurement == null ? '${c.testName}/${c.phaseName}' : '${c.testName}/${c.phaseName}/${c.measurement}';
      final drift = c.referencedHash != e.spec.hash ? '  (pinned ${c.referencedHash} != ${e.spec.hash})' : '';
      out.writeln('      <- $where [${c.outcome.name}]$drift');
    }
  }

  if (matrix.unknownRefs.isNotEmpty) {
    out.writeln('  unknown requirement references:');
    for (final c in matrix.unknownRefs) {
      out.writeln('      ${c.requirementId} <- ${c.testName}/${c.phaseName}');
    }
  }

  out.writeln('  result: ${matrix.ok(minCoverage: minCoverage) ? 'OK' : 'FAIL'}');
  return out.toString();
}

/// A machine-readable view of [matrix] (the same information as [traceReport])
/// for CI gates and dashboards. JSON-encodable with `dart:convert`. Shape:
/// `{ok, coverage, covered, total, requirements: [{id, hash, text?, covered,
/// outcome, drift, coverage: [{where, testName, phaseName, measurement?,
/// outcome, referencedHash, drift}]}], unknownRefs: [...]}`.
Map<String, Object?> traceMatrixToJson(TraceMatrix matrix, {double minCoverage = 1.0}) {
  Map<String, Object?> refJson(CoverageRef c, String specHash) => {
        'where': c.measurement == null
            ? '${c.testName}/${c.phaseName}'
            : '${c.testName}/${c.phaseName}/${c.measurement}',
        'testName': c.testName,
        'phaseName': c.phaseName,
        if (c.measurement != null) 'measurement': c.measurement,
        'outcome': c.outcome.name,
        'referencedHash': c.referencedHash,
        'drift': c.referencedHash != specHash,
      };

  return {
    'ok': matrix.ok(minCoverage: minCoverage),
    'coverage': matrix.coverage,
    'covered': matrix.entries.where((e) => e.isCovered).length,
    'total': matrix.entries.length,
    'requirements': [
      for (final e in matrix.entries)
        {
          'id': e.spec.id,
          'hash': e.spec.hash,
          if (e.spec.text != null) 'text': e.spec.text,
          'covered': e.isCovered,
          'outcome': e.isCovered ? e.outcome.name : null,
          'drift': e.hasDrift,
          'coverage': [for (final c in e.coverage) refJson(c, e.spec.hash)],
        },
    ],
    'unknownRefs': [
      for (final c in matrix.unknownRefs)
        {
          'requirementId': c.requirementId,
          'where': c.measurement == null
              ? '${c.testName}/${c.phaseName}'
              : '${c.testName}/${c.phaseName}/${c.measurement}',
          'outcome': c.outcome.name,
        },
    ],
  };
}

/// Extracts coverage refs from a serialized record. Tolerant of malformed input
/// (hand-edited/corrupt JSON): uses `is` checks and skips anything ill-shaped
/// rather than throwing, so a bad record yields a partial/empty result.
List<CoverageRef> _refsFromRecordJson(Map<String, Object?> record) {
  final testName = '${record['testName'] ?? 'unknown'}';
  final out = <CoverageRef>[];

  void addRefs(Object? reqs, String phaseName, String? measurement, Outcome outcome) {
    if (reqs is! List) return;
    for (final r in reqs) {
      if (r is! Map) continue;
      final id = r['id'];
      if (id == null) continue;
      out.add(CoverageRef(
        requirementId: '$id',
        testName: testName,
        phaseName: phaseName,
        measurement: measurement,
        outcome: outcome,
        referencedHash: '${r['hash'] ?? ''}',
      ));
    }
  }

  final phases = record['phases'];
  if (phases is! List) return out;
  for (final p in phases) {
    if (p is! Map) continue;
    final phaseName = '${p['name'] ?? ''}';
    addRefs(p['requirements'], phaseName, null, Outcome.fromName(p['outcome']));
    final measurements = p['measurements'];
    if (measurements is List) {
      for (final m in measurements) {
        if (m is! Map) continue;
        addRefs(m['requirements'], phaseName, '${m['name'] ?? ''}', Outcome.fromName(m['outcome']));
      }
    }
  }
  return out;
}

/// Builds a trace matrix from serialized `record.json` maps (as written by the
/// runner). Lets CI gate on persisted records without re-running tests.
TraceMatrix buildTraceMatrixFromRecordJson(
  Map<String, RequirementSpec> requirements,
  Iterable<Map<String, Object?>> records,
) =>
    _matrixFromRefs(requirements, [for (final r in records) ..._refsFromRecordJson(r)]);
