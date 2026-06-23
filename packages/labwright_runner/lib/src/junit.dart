/// JUnit XML export for Labwright records, so runs surface natively in GitHub
/// Actions and most CI test UIs. A record (from `TestRecord.toJson`,
/// `record.json`, or [tdmsToRecordJson]) becomes one `<testsuite>` with one
/// `<testcase>` per phase; a phase's outcome maps to `<failure>` (fail),
/// `<error>` (error) or `<skipped>` (skip). Measurements ride along as
/// `<system-out>`, and failing measurements are named in the failure message.
///
/// Built as a plain string with proper escaping — no XML dependency. Tolerant of
/// partial records (e.g. a `.tdms`-reconstructed one with no durations); an
/// unknown or missing phase outcome is classified as [Outcome.error] (fail-safe
/// for CI) via [Outcome.fromName].
library;

import 'package:labwright_core/labwright_core.dart';

/// One record → a standalone JUnit document with a single `<testsuite>`.
String recordJsonToJUnit(Map<String, Object?> record) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n${_suite(record).xml}';

/// Several records → one JUnit document with a `<testsuites>` root wrapping one
/// `<testsuite>` per record, with aggregate counts. This is how sharded CI runs
/// combine into a single ingestible report.
String recordsToJUnitSuites(List<Map<String, Object?>> records) {
  final suites = [for (final r in records) _suite(r)];
  final tests = suites.fold(0, (a, s) => a + s.tests);
  final failures = suites.fold(0, (a, s) => a + s.failures);
  final errors = suites.fold(0, (a, s) => a + s.errors);
  final skipped = suites.fold(0, (a, s) => a + s.skipped);

  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<testsuites tests="$tests" failures="$failures" errors="$errors" skipped="$skipped">');
  for (final s in suites) {
    b.write(s.xml);
  }
  b.writeln('</testsuites>');
  return b.toString();
}

typedef _Suite = ({String xml, int tests, int failures, int errors, int skipped});

/// Builds the `<testsuite>…</testsuite>` block (no XML declaration) plus the
/// counts the `<testsuites>` root aggregates. Shared by both entry points.
_Suite _suite(Map<String, Object?> record) {
  final testName = '${record['testName'] ?? 'labwright'}';
  final phases = _maps(record['phases']);

  var failures = 0;
  var errors = 0;
  var skipped = 0;
  for (final p in phases) {
    switch (Outcome.fromName(p['outcome'])) {
      case Outcome.fail:
        failures++;
      case Outcome.error:
        errors++;
      case Outcome.skip:
        skipped++;
      case Outcome.pass:
        break;
    }
  }

  final b = StringBuffer()
    ..write('<testsuite name="${_attr(testName)}" tests="${phases.length}"')
    ..write(' failures="$failures" errors="$errors" skipped="$skipped"');
  final suiteTime = _seconds(record['durationMs']);
  if (suiteTime != null) b.write(' time="$suiteTime"');
  if (record['dutId'] != null) b.write(' hostname="${_attr('${record['dutId']}')}"');
  b.writeln('>');

  for (final p in phases) {
    final name = '${p['name'] ?? ''}';
    final outcome = Outcome.fromName(p['outcome']);
    final time = _seconds(p['durationMs']);
    final measurements = _maps(p['measurements']);

    b.write('  <testcase name="${_attr(name)}" classname="${_attr(testName)}"');
    if (time != null) b.write(' time="$time"');
    b.writeln('>');

    if (outcome == Outcome.skip) {
      b.writeln('    <skipped/>');
    } else if (outcome == Outcome.fail || outcome == Outcome.error) {
      final failed = [
        for (final m in measurements)
          if (Outcome.fromName(m['outcome']) == Outcome.fail || Outcome.fromName(m['outcome']) == Outcome.error)
            '${m['name']}',
      ];
      final detail = p['error'] != null
          ? '${p['error']}'
          : failed.isNotEmpty
              ? 'failing measurements: ${failed.join(', ')}'
              : 'phase $name ${outcome.name}';
      final tag = outcome == Outcome.error ? 'error' : 'failure';
      b.writeln('    <$tag message="${_attr(detail)}">${_text(detail)}</$tag>');
    }

    if (measurements.isNotEmpty) {
      final lines = [
        for (final m in measurements) '${m['name']}: ${m['outcome']}${m['value'] != null ? ' = ${m['value']}' : ''}',
      ];
      b.writeln('    <system-out>${_text(lines.join('\n'))}</system-out>');
    }
    b.writeln('  </testcase>');
  }

  b.writeln('</testsuite>');
  return (xml: b.toString(), tests: phases.length, failures: failures, errors: errors, skipped: skipped);
}

/// List elements that are maps, normalized to `Map<String, Object?>`. Empty for
/// anything that isn't a list (so partial/garbage records degrade gracefully).
List<Map<String, Object?>> _maps(Object? v) =>
    v is List ? [for (final e in v) if (e is Map) e.cast<String, Object?>()] : const [];

/// Milliseconds (any num) → a seconds string, or null when absent/non-numeric.
String? _seconds(Object? ms) => ms is num ? (ms / 1000).toStringAsFixed(3) : null;

/// Escapes text content (`&`, `<`, `>`).
String _text(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Escapes an attribute value (text plus quotes).
String _attr(String s) => _text(s).replaceAll('"', '&quot;').replaceAll("'", '&apos;');
