@Tags(['corpus'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

import 'corpus_dirs.dart';

/// Validates the old-format TOF1 property-record grammar ([binaryPropertyRecords])
/// against the **content-exact Rosetta twin**: a binary `.seq` and its XML export
/// carry the same sequences, so every value decoded from the binary must equal the
/// value the XML records for that property. The `OutputVoltage_{BIN,XML}` pair is
/// fetched into `corpus/seq/rosetta/`; this test skips when the corpus is absent.
File? _rosetta(String name) {
  final f = File('${corpusSeqDir.path}/rosetta/$name');
  return f.existsSync() ? f : null;
}

/// Extracts `<PropName ...><value>V</value>` occurrences from an XML twin,
/// grouped by property name (a name can recur at different tree positions).
Map<String, Set<String>> _xmlValues(String xml) {
  final out = <String, Set<String>>{};
  final re = RegExp(r'<([A-Za-z_][A-Za-z0-9_]*)\b[^>]*>\s*<value>([^<]*)</value>');
  for (final m in re.allMatches(xml)) {
    (out[m.group(1)!] ??= <String>{}).add(m.group(2)!.replaceAll('"', '').trim());
  }
  return out;
}

String _asXmlText(Object? value) {
  if (value is bool) return value ? 'true' : 'false';
  if (value is double) {
    return value == value.truncateToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
  return (value ?? '').toString().replaceAll('"', '').trim();
}

void main() {
  final bin = _rosetta('OutputVoltage_BIN.seq');
  final xml = _rosetta('OutputVoltage_XML.seq');
  if (bin == null || xml == null) {
    test('binary property records (skipped: Rosetta corpus not fetched)', () {},
        skip: true);
    return;
  }

  final records =
      binaryPropertyRecords(Uint8List.fromList(bin.readAsBytesSync()));
  final xmlValues = _xmlValues(xml.readAsStringSync());

  test('decodes valued property records from the binary body', () {
    expect(records, isNotEmpty);
    expect(records.where((r) => r.value != null), isNotEmpty,
        reason: 'the grammar must recover inline values, not just names');
  });

  test('every decoded value matches the content-exact XML twin', () {
    // A binary value is confirmed when the XML records that exact value for the
    // same property somewhere in the tree. (A flat scan cannot pin WHICH
    // occurrence of a duplicated name it is, so membership — not position — is
    // the honest check until the container nesting is decoded.)
    var checked = 0;
    var confirmed = 0;
    final unmatched = <String>[];
    for (final record in records) {
      if (record.value == null) continue;
      final xmlForName = xmlValues[record.name];
      if (xmlForName == null) continue; // nested-only / absent name: not checkable here
      checked++;
      if (xmlForName.contains(_asXmlText(record.value))) {
        confirmed++;
      } else if (unmatched.length < 6) {
        unmatched.add('${record.name}=${_asXmlText(record.value)} '
            'not in {${xmlForName.join(', ')}}');
      }
    }
    expect(checked, greaterThanOrEqualTo(8),
        reason: 'the twin should share several checkable property names');
    expect(confirmed, checked,
        reason: 'every checkable decoded value must appear in the XML twin; '
            'unmatched: ${unmatched.join(' | ')}');
  });

  test('specific TestStand defaults decode exactly (incl. a non-round double)', () {
    Object? valueOf(String name) =>
        records.where((r) => r.name == name && r.value != null).firstOrNull?.value;
    // Priority's default is a large non-round double NI's clean-bits scalar
    // heuristic would drop — the typed grammar recovers it.
    expect(valueOf('Priority'), 2953567917.0);
    expect(valueOf('BatchSync'), 1.0);
    expect(valueOf('RecordResults'), isTrue);
    expect(valueOf('OptimizeNonReentrantCalls'), isTrue);
    expect(valueOf('EPNameExpr'), contains('Unnamed Entry Point'));
  });
}
