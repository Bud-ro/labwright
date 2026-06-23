import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_runner/labwright_runner.dart';
import 'package:labwright_tdms/labwright_tdms.dart';
import 'package:labwright_traceability/labwright_traceability.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

/// Process exit codes the CLI returns, following the `sysexits.h` convention
/// (64 usage, 65 data, 66 no-input) plus 0 ok and 1 "ran fine but the check
/// failed" (e.g. a trace gate or a diff that differs).
abstract final class ExitCodes {
  static const int ok = 0;
  static const int failure = 1; // command ran but its check failed (trace/diff/lint)
  static const int usage = 64; // bad invocation / arguments
  static const int badInput = 65; // unreadable/ill-formed file content
  static const int missingFile = 66; // a required input file does not exist
}

const String usage = '''
labwright — NI data toolkit

usage: labwright <command> [args]

commands:
  tdms-inspect <file.tdms>                   human-readable TDMS summary
  tdms-csv     <file.tdms>                   TDMS numeric channels as CSV
  tdms-summary <file.tdms>                   TDMS structure as JSON
  tdms-diff [--json] [--tol <x>] <a.tdms> <b.tdms>  compare two TDMS files (exit 1 if they differ)
  tdms-merge   <out.tdms> <in1.tdms> <in2.tdms>...  union channels of several TDMS files into one archive
  csv2tdms     <in.csv> <out.tdms>           import CSV columns into a TDMS file
  vi-inspect   <file.vi>                     LabVIEW VI summary (RSRC)
  vi-summary   <file.vi>                     LabVIEW VI summary as JSON
  reqs-lint <reqs.json>                      validate a requirements file (dup ids, empty hashes); exit 1 if issues
  trace [--json] [--min-coverage <f>] <reqs.json> <record.json|.tdms>...  requirement trace matrix (exit 1 if failing)
  junit <record.json|.tdms>...               JUnit XML for CI test UIs (stdout; 2+ files -> aggregate)
''';

/// Dispatches a subcommand. Pure of process globals (I/O via [out]/[err], exit
/// code returned) so it is unit-testable. See [ExitCodes] for the returned
/// codes ([ExitCodes.ok], [ExitCodes.failure], [ExitCodes.usage],
/// [ExitCodes.badInput], [ExitCodes.missingFile]).
/// CLI version (matches the package version).
const String version = '0.0.1';

int run(List<String> args, {required StringSink out, required StringSink err}) {
  if (args.isEmpty) {
    err.writeln(usage);
    return ExitCodes.usage;
  }
  switch (args.first) {
    case '-h':
    case '--help':
    case 'help':
      out.writeln(usage);
      return ExitCodes.ok;
    case '-v':
    case '--version':
    case 'version':
      out.writeln('labwright $version');
      return ExitCodes.ok;
  }
  final rest = args.sublist(1);
  switch (args.first) {
    case 'tdms-inspect':
      return _withBytes(rest, err, (b) {
        out.writeln(inspectTdms(b));
        return ExitCodes.ok;
      });
    case 'tdms-csv':
      return _withBytes(rest, err, (b) {
        out.write(tdmsToCsv(b));
        return ExitCodes.ok;
      });
    case 'tdms-summary':
      return _withBytes(rest, err, (b) {
        out.writeln(const JsonEncoder.withIndent('  ').convert(tdmsSummary(b)));
        return ExitCodes.ok;
      });
    case 'vi-inspect':
      return _withBytes(rest, err, (b) {
        final vi = parseVi(b);
        out
          ..writeln(vi.describe())
          ..writeln('  blocks: ${vi.blocks.join(', ')}');
        return ExitCodes.ok;
      });
    case 'vi-summary':
      return _withBytes(rest, err, (b) {
        out.writeln(const JsonEncoder.withIndent('  ').convert(parseVi(b).toJson()));
        return ExitCodes.ok;
      });
    case 'csv2tdms':
      if (rest.length < 2) {
        err.writeln('usage: labwright csv2tdms <in.csv> <out.tdms>');
        return ExitCodes.usage;
      }
      final inFile = File(rest[0]);
      if (!inFile.existsSync()) {
        err.writeln('no such file: ${rest[0]}');
        return ExitCodes.missingFile;
      }
      File(rest[1]).writeAsBytesSync(csvToTdms(inFile.readAsStringSync()));
      out.writeln('wrote ${rest[1]}');
      return ExitCodes.ok;
    case 'tdms-diff':
      return _tdmsDiff(rest, out, err);
    case 'tdms-merge':
      return _tdmsMerge(rest, out, err);
    case 'trace':
      return _trace(rest, out, err);
    case 'reqs-lint':
      return _reqsLint(rest, out, err);
    case 'junit':
      return _junit(rest, out, err);
    default:
      err
        ..writeln('unknown command: ${args.first}')
        ..writeln()
        ..writeln(usage);
      return ExitCodes.usage;
  }
}

/// A record source is TDMS if the path ends in `.tdms` or the bytes begin with
/// the `TDSm` segment tag (0x54 0x44 0x53 0x6D) — so detection works even when
/// the extension is missing.
bool _looksLikeTdms(String path, Uint8List bytes) {
  if (path.toLowerCase().endsWith('.tdms')) return true;
  return bytes.length >= 4 && bytes[0] == 0x54 && bytes[1] == 0x44 && bytes[2] == 0x53 && bytes[3] == 0x6D;
}

int _withBytes(List<String> rest, StringSink err, int Function(Uint8List bytes) body) {
  if (rest.isEmpty) {
    err.writeln('expected a file argument');
    return ExitCodes.usage;
  }
  final file = File(rest.first);
  if (!file.existsSync()) {
    err.writeln('no such file: ${rest.first}');
    return ExitCodes.missingFile;
  }
  try {
    return body(file.readAsBytesSync());
  } on TdmsFormatException catch (e) {
    err.writeln(e);
    return ExitCodes.badInput;
  } on ViFormatException catch (e) {
    err.writeln(e);
    return ExitCodes.badInput;
  }
}

int _tdmsDiff(List<String> argv, StringSink out, StringSink err) {
  const usageLine = 'usage: labwright tdms-diff [--json] [--tol <x>] <a.tdms> <b.tdms>';
  var asJson = false;
  var tol = 0.0;
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--json') {
      asJson = true;
    } else if (a == '--tol' || a.startsWith('--tol=')) {
      final raw = a == '--tol' ? (i + 1 < argv.length ? argv[++i] : null) : a.substring('--tol='.length);
      final value = raw == null ? null : double.tryParse(raw);
      if (value == null || value < 0.0) {
        err.writeln('invalid --tol (want a non-negative number): ${raw ?? '<missing>'}');
        return ExitCodes.usage;
      }
      tol = value;
    } else {
      rest.add(a);
    }
  }
  if (rest.length != 2) {
    err.writeln(usageLine);
    return ExitCodes.usage;
  }
  for (final path in rest) {
    if (!File(path).existsSync()) {
      err.writeln('no such file: $path');
      return ExitCodes.missingFile;
    }
  }
  final Map<String, Object?> diff;
  try {
    diff = diffTdms(
      TdmsReader.read(File(rest[0]).readAsBytesSync()),
      TdmsReader.read(File(rest[1]).readAsBytesSync()),
      tol: tol,
    );
  } on TdmsFormatException catch (e) {
    err.writeln(e);
    return ExitCodes.badInput;
  }
  final identical = diff['identical'] == true;
  if (asJson) {
    out.writeln(const JsonEncoder.withIndent('  ').convert(diff));
  } else {
    out.writeln(_diffReport(diff));
  }
  return identical ? ExitCodes.ok : ExitCodes.failure;
}

int _tdmsMerge(List<String> rest, StringSink out, StringSink err) {
  if (rest.length < 3) {
    err.writeln('usage: labwright tdms-merge <out.tdms> <in1.tdms> <in2.tdms>...');
    return ExitCodes.usage;
  }
  final outPath = rest.first;
  final inputs = <TdmsFile>[];
  try {
    for (final path in rest.sublist(1)) {
      if (!File(path).existsSync()) {
        err.writeln('no such file: $path');
        return ExitCodes.missingFile;
      }
      inputs.add(TdmsReader.read(File(path).readAsBytesSync()));
    }
  } on TdmsFormatException catch (e) {
    err.writeln(e);
    return ExitCodes.badInput;
  }
  File(outPath).writeAsBytesSync(mergeTdms(inputs));
  out.writeln('wrote $outPath (${inputs.length} files merged)');
  return ExitCodes.ok;
}

int _reqsLint(List<String> rest, StringSink out, StringSink err) {
  if (rest.length != 1) {
    err.writeln('usage: labwright reqs-lint <reqs.json>');
    return ExitCodes.usage;
  }
  final file = File(rest.first);
  if (!file.existsSync()) {
    err.writeln('no such file: ${rest.first}');
    return ExitCodes.missingFile;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    err.writeln('${rest.first}: $e');
    return ExitCodes.badInput;
  }
  final issues = lintRequirements(decoded);
  if (issues.isEmpty) {
    out.writeln('OK: ${rest.first} is well-formed');
    return ExitCodes.ok;
  }
  for (final issue in issues) {
    out.writeln(issue);
  }
  return ExitCodes.failure;
}

int _junit(List<String> rest, StringSink out, StringSink err) {
  if (rest.isEmpty) {
    err.writeln('usage: labwright junit <record.json|.tdms>...');
    return ExitCodes.usage;
  }
  final records = <Map<String, Object?>>[];
  for (final path in rest) {
    final (code, record) = _loadRecord(path, err);
    if (record == null) return code;
    records.add(record);
  }
  // One record -> a single <testsuite>; several -> a <testsuites> aggregate
  // (combining sharded CI runs into one report).
  out.write(records.length == 1 ? recordJsonToJUnit(records.single) : recordsToJUnitSuites(records));
  return ExitCodes.ok;
}

/// Loads one record source — a `record.json` or a self-describing `.tdms`
/// (reconstructed via [tdmsToRecordJson]) — into the record-JSON map. Returns
/// `(ExitCodes.ok, record)` on success, or `(code, null)` with an error written
/// to [err] ([ExitCodes.missingFile] or [ExitCodes.badInput]).
(int, Map<String, Object?>?) _loadRecord(String path, StringSink err) {
  final file = File(path);
  if (!file.existsSync()) {
    err.writeln('no such file: $path');
    return (ExitCodes.missingFile, null);
  }
  final bytes = file.readAsBytesSync();
  try {
    if (_looksLikeTdms(path, bytes)) return (ExitCodes.ok, tdmsToRecordJson(TdmsReader.read(bytes)));
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) return (ExitCodes.ok, decoded.cast<String, Object?>());
    err.writeln('$path: not a record object');
    return (ExitCodes.badInput, null);
  } on TdmsFormatException catch (e) {
    err.writeln('$path: $e');
    return (ExitCodes.badInput, null);
  } on FormatException catch (e) {
    err.writeln('$path: $e');
    return (ExitCodes.badInput, null);
  }
}

String _diffReport(Map<String, Object?> diff) {
  if (diff['identical'] == true) return 'TDMS files are identical (within tol ${diff['tol']}).';
  final b = StringBuffer('TDMS files differ (tol ${diff['tol']}):');
  for (final g in diff['groupsOnlyInA'] as List) {
    b.write('\n  group only in A: $g');
  }
  for (final g in diff['groupsOnlyInB'] as List) {
    b.write('\n  group only in B: $g');
  }
  for (final c in (diff['channels'] as List).cast<Map<String, Object?>>()) {
    b.write('\n  ${c['group']}/${c['name']}: ${c['status']}');
    if (c['status'] == ChannelDiffStatus.lengthMismatch.name) b.write(' (lenA=${c['lenA']} lenB=${c['lenB']})');
    if (c['firstDiffIndex'] != null) b.write(' first@${c['firstDiffIndex']} maxAbsDelta=${c['maxAbsDelta']}');
  }
  return b.toString();
}

int _trace(List<String> argv, StringSink out, StringSink err) {
  const usageLine = 'usage: labwright trace [--json] [--min-coverage <0.0-1.0>] <reqs.json> <record.json|.tdms>...';
  var asJson = false;
  var minCoverage = 1.0;
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--json') {
      asJson = true;
    } else if (a == '--min-coverage' || a.startsWith('--min-coverage=')) {
      final raw = a == '--min-coverage' ? (i + 1 < argv.length ? argv[++i] : null) : a.substring('--min-coverage='.length);
      final value = raw == null ? null : double.tryParse(raw);
      if (value == null || value < 0.0 || value > 1.0) {
        err.writeln('invalid --min-coverage (want a fraction 0.0-1.0): ${raw ?? '<missing>'}');
        return ExitCodes.usage;
      }
      minCoverage = value;
    } else {
      rest.add(a);
    }
  }
  if (rest.length < 2) {
    err.writeln(usageLine);
    return ExitCodes.usage;
  }
  final reqFile = File(rest.first);
  if (!reqFile.existsSync()) {
    err.writeln('no such file: ${rest.first}');
    return ExitCodes.missingFile;
  }
  final specs = parseRequirements(jsonDecode(reqFile.readAsStringSync()));
  final records = <Map<String, Object?>>[];
  for (final path in rest.sublist(1)) {
    final (code, record) = _loadRecord(path, err);
    if (record == null) return code;
    records.add(record);
  }
  final matrix = buildTraceMatrixFromRecordJson(specs, records);
  if (asJson) {
    out.writeln(const JsonEncoder.withIndent('  ').convert(traceMatrixToJson(matrix, minCoverage: minCoverage)));
  } else {
    out.write(traceReport(matrix, minCoverage: minCoverage));
  }
  return matrix.ok(minCoverage: minCoverage) ? ExitCodes.ok : ExitCodes.failure;
}
