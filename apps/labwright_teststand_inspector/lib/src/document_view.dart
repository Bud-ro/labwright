import 'package:labwright_teststand/labwright_teststand.dart';

/// Pure rendering of a [SeqDocument] to a text view (kept Flutter-free so it is
/// unit-testable). XML files render the faithful sequence dump; binary files
/// render an honest recon view; unknown files render the header + error.
String documentText(SeqDocument doc) {
  switch (doc) {
    case StructuredSeqDocument(:final file):
      return dumpSeqFile(file);
    case BinarySeqDocument(
        :final header,
        :final inflatedSize,
        :final stringTable,
        :final objectNames,
        :final modulePaths,
        :final stepReferences,
        :final expressions,
        :final quotedLiterals,
      ):
      final b = StringBuffer()
        ..writeln('$header')
        ..writeln('binary TOF1 — record tree not yet decoded (recon view)')
        ..writeln('inflated body: $inflatedSize bytes · '
            '${stringTable.length} strings in the largest table');
      // Recovered datums from the string pool. Honest: these are the NAMES /
      // call-targets / step refs / expressions a file carries — *which* it uses,
      // not yet *attached to a specific step* (the record grammar is undecoded).
      void section(String title, List<String> items) {
        if (items.isEmpty) return;
        b
          ..writeln()
          ..writeln('$title (${items.length}; record links not yet decoded):');
        writeCapped(b, items, (n) => n);
      }

      section('recovered property/object names', objectNames);
      section('module call-targets', modulePaths);
      section('step references', stepReferences);
      section('expressions (test logic)', expressions);
      section('quoted literals (values)', quotedLiterals);
      b
        ..writeln()
        ..writeln('largest string table:');
      writeCapped(b, stringTable, (s) => s.text);
      return b.toString();
    case UnknownSeqDocument(:final header, :final error):
      return 'Not a recognized TestStand sequence.\n$header'
          '${error != null ? '\n\n$error' : ''}';
  }
}

/// Max entries listed for a long recovered-name / string table in the recon
/// view before the remainder is summarized — keeps the output readable without
/// silently hiding the true count.
const maxListedEntries = 200;

/// Appends up to [maxListedEntries] of [items] (rendered via [line], indented)
/// to [b]; if there were more, appends an honest `… and N more` line rather than
/// truncating silently.
void writeCapped<T>(StringBuffer b, List<T> items, String Function(T) line) {
  for (final item in items.take(maxListedEntries)) {
    b.writeln('  ${line(item)}');
  }
  final hidden = items.length - maxListedEntries;
  if (hidden > 0) b.writeln('  … and $hidden more');
}

/// A one-line title for a document (for the app bar / file label).
String documentTitle(SeqDocument doc) {
  final h = doc.header;
  final kind = switch (doc) {
    StructuredSeqDocument(:final file) => '${file.sequences.length} sequences',
    BinarySeqDocument() => 'binary (recon)',
    UnknownSeqDocument() => 'unrecognized',
  };
  return '${h.fileType ?? 'TestStand'} · ${h.format.name} · $kind';
}

/// The recovered-datum categories of a binary `TOF1` document as
/// (title, items) groups, omitting empty ones — for collapsible UI sections.
/// Pure. Each title states the count; the items are the recovered strings.
List<({String title, List<String> items})> binaryRecoverySections(
  BinarySeqDocument doc,
) {
  return [
    (title: 'Object names', items: doc.objectNames),
    (title: 'Module call-targets', items: doc.modulePaths),
    (title: 'Step references', items: doc.stepReferences),
    (title: 'Expressions (test logic)', items: doc.expressions),
    (title: 'Quoted literals (values)', items: doc.quotedLiterals),
  ].where((s) => s.items.isNotEmpty).toList();
}

/// Header/recon facts for a binary `TOF1` document, as label→value rows for a
/// small table. Pure. Only includes what the reader actually recovered (no
/// build/compatible version is stored on the header yet, so it isn't shown).
List<(String, String)> binaryHeaderRows(BinarySeqDocument doc) {
  final h = doc.header;
  return [
    ('Encoding', h.format.name),
    ('File type', h.fileType ?? '(not recovered)'),
    ('Product', h.productName ?? '(not recovered)'),
    if (h.fileVersion != null) ('File version', h.fileVersion!),
    (
      'Inflated body',
      doc.inflatedSize > 0 ? '${doc.inflatedSize} bytes' : '(not inflated)'
    ),
    ('Strings recovered', '${doc.strings.length}'),
    ('Largest string table', '${doc.stringTable.length}'),
    // The framed body layout (record region + string region), when it framed.
    if (doc.layout case final l?) ...[
      ('Record region', '${l.recordRegionLength} bytes'),
      ('String region @', '${l.stringRegionOffset}'),
      ('Record sentinels', '${l.sentinelCount}'),
      ('Strings in region', '${l.stringCount}'),
      ('String tables', '${l.segmentCount}'),
      if (doc.nameTable.isNotEmpty)
        ('Property-name table', '${doc.nameTable.length} entries'),
      if (l.leadingWords.isNotEmpty)
        ('Record header words', l.leadingWords.join(', ')),
    ],
    // Recovered string-pool datums (record links not yet decoded).
    if (doc.objectNames.isNotEmpty)
      ('Object names', '${doc.objectNames.length}'),
    if (doc.modulePaths.isNotEmpty)
      ('Module call-targets', '${doc.modulePaths.length}'),
    if (doc.stepReferences.isNotEmpty)
      ('Step references', '${doc.stepReferences.length}'),
    if (doc.expressions.isNotEmpty)
      ('Expressions', '${doc.expressions.length}'),
    if (doc.quotedLiterals.isNotEmpty)
      ('Quoted literals', '${doc.quotedLiterals.length}'),
  ];
}

/// A one-line label for model coverage, e.g. `model coverage 13.5% (1895/14016)`
/// — how much of the raw PropertyObject tree the typed lens accounts for. Pure.
String coverageLabel(SeqCoverage c) {
  final pct = (c.ratio * 100).toStringAsFixed(1);
  return 'model coverage $pct% (${c.modeled}/${c.total})';
}
