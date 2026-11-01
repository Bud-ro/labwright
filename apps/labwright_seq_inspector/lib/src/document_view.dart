import 'package:labwright_seq/labwright_seq.dart';

String documentText(SeqDocument doc) {
  switch (doc) {
    case StructuredSeqDocument(:final file):
      return dumpSeqFile(file);
    case BinarySeqDocument(:final header, :final partialFile, :final error):
      final out = StringBuffer()..writeln('$header');
      if (partialFile != null)
        return (out..write(dumpSeqFile(partialFile))).toString();
      out
        ..writeln('binary TOF1 — record grammar not yet decoded for this body')
        ..writeln(error ?? 'the body does not inflate');
      for (final section in binaryRecoverySections(doc)) {
        out
          ..writeln()
          ..writeln('${section.title} (${section.items.length}):');
        writeCapped(out, section.items, (n) => n);
      }
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
    BinarySeqDocument(:final partialFile?) =>
      '${partialFile.sequences.length} sequences',
    BinarySeqDocument() => 'binary (not decoded)',
    UnknownSeqDocument() => 'unrecognized',
  };
  return '${header.fileType ?? 'TestStand'} · ${header.format.name} · $kind';
}

List<({String title, List<String> items})> binaryRecoverySections(
  BinarySeqDocument doc,
) => [
  (title: 'Module call-targets', items: doc.modulePaths),
  (title: 'Step references', items: doc.stepReferences),
  (title: 'Expressions (test logic)', items: doc.expressions),
  (title: 'Quoted literals (values)', items: doc.quotedLiterals),
].where((s) => s.items.isNotEmpty).toList();

List<(String, String)> binaryHeaderRows(BinarySeqDocument doc) {
  final header = doc.header;
  final body = doc.partialFile?.binary;
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
    if (body != null) ...[
      ('Generation', body.generation.name),
      ('Record region', '${body.recordRegionLength} bytes'),
      ('Types', '${body.types.length}'),
    ],
    if (doc.error case final error?) ('Not decoded', error),
    for (final section in binaryRecoverySections(doc))
      (section.title, '${section.items.length}'),
  ];
}

String coverageLabel(SeqCoverage c) {
  final pct = (c.ratio * 100).toStringAsFixed(1);
  return 'model coverage $pct% (${c.modeled}/${c.total})';
}
