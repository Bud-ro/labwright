import 'package:labwright_seq/labwright_seq.dart';

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
      final out = StringBuffer()
        ..writeln('$header')
        ..writeln('binary TOF1 — record tree not yet decoded (recon view)')
        ..writeln(
          'inflated body: $inflatedSize bytes · '
          '${stringTable.length} strings in the largest table',
        );
      void section(String title, List<String> items) {
        if (items.isEmpty) return;
        out
          ..writeln()
          ..writeln('$title (${items.length}; record links not yet decoded):');
        writeCapped(out, items, (n) => n);
      }

      section('recovered property/object names', objectNames);
      section('module call-targets', modulePaths);
      section('step references', stepReferences);
      section('expressions (test logic)', expressions);
      section('quoted literals (values)', quotedLiterals);
      out
        ..writeln()
        ..writeln('largest string table:');
      writeCapped(out, stringTable, (s) => s.text);
      return out.toString();
    case UnknownSeqDocument(:final header, :final error):
      return 'Not a recognized TestStand sequence.\n$header'
          '${error != null ? '\n\n$error' : ''}';
  }
}

const maxListedEntries = 200;

void writeCapped<T>(StringBuffer b, List<T> items, String Function(T) line) {
  for (final item in items.take(maxListedEntries)) {
    b.writeln('  ${line(item)}');
  }
  final hidden = items.length - maxListedEntries;
  if (hidden > 0) b.writeln('  … and $hidden more');
}

String documentTitle(SeqDocument doc) {
  final header = doc.header;
  final kind = switch (doc) {
    StructuredSeqDocument(:final file) => '${file.sequences.length} sequences',
    BinarySeqDocument() => 'binary (recon)',
    UnknownSeqDocument() => 'unrecognized',
  };
  return '${header.fileType ?? 'TestStand'} · ${header.format.name} · $kind';
}

List<({String title, List<String> items})> binaryRecoverySections(
  BinarySeqDocument doc,
) {
  return [
    (title: 'Object names', items: doc.objectNames),
    (title: 'Module call-targets', items: doc.modulePaths),
    (title: 'Step references', items: doc.stepReferences),
    (title: 'Expressions (test logic)', items: doc.expressions),
    (title: 'Quoted literals (values)', items: doc.quotedLiterals),
    (
      title: 'Named scalar values',
      items: [
        for (final scalar in doc.namedScalars)
          '${scalar.name} = ${scalar.value}  (raw type ${scalar.rawTypeCode}, not modeled)',
      ],
    ),
    (
      title: 'Inline numeric values',
      items: [for (final value in doc.scalarDoubles) '$value'],
    ),
    (
      title: 'Named-record headers',
      items: [
        for (final record in doc.namedRecords)
          '${record.name} ×${record.count}  (raw tag ${record.rawTag}, not modeled)',
      ],
    ),
  ].where((s) => s.items.isNotEmpty).toList();
}

List<(String, String)> binaryHeaderRows(BinarySeqDocument doc) {
  final header = doc.header;
  return [
    ('Encoding', header.format.name),
    ('File type', header.fileType ?? '(not recovered)'),
    ('Product', header.productName ?? '(not recovered)'),
    if (header.fileVersion != null) ('File version', header.fileVersion!),
    (
      'Inflated body',
      doc.inflatedSize > 0 ? '${doc.inflatedSize} bytes' : '(not inflated)',
    ),
    ('Strings recovered', '${doc.strings.length}'),
    ('Largest string table', '${doc.stringTable.length}'),
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
    if (doc.scalarDoubles.isNotEmpty)
      ('Inline numbers', '${doc.scalarDoubles.length}'),
    if (doc.namedScalars.isNotEmpty)
      ('Named scalars', '${doc.namedScalars.length}'),
    if (doc.namedRecords.isNotEmpty)
      ('Named records', '${doc.namedRecords.length}'),
  ];
}

String coverageLabel(SeqCoverage c) {
  final pct = (c.ratio * 100).toStringAsFixed(1);
  return 'model coverage $pct% (${c.modeled}/${c.total})';
}
