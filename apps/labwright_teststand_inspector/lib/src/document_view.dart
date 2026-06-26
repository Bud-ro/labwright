import 'package:labwright_teststand/labwright_teststand.dart';

/// Pure rendering of a [SeqDocument] to a text view (kept Flutter-free so it is
/// unit-testable). XML files render the faithful sequence dump; binary files
/// render an honest recon view; unknown files render the header + error.
String documentText(SeqDocument doc) {
  switch (doc) {
    case XmlSeqDocument(:final file):
      return dumpSeqFile(file);
    case BinarySeqDocument(:final header, :final inflatedSize, :final stringTable):
      final b = StringBuffer()
        ..writeln('$header')
        ..writeln('binary TOF1 — record tree not yet decoded (recon view)')
        ..writeln('inflated body: $inflatedSize bytes · '
            '${stringTable.length} strings in the largest table')
        ..writeln();
      for (final s in stringTable.take(200)) {
        b.writeln('  ${s.text}');
      }
      return b.toString();
    case UnknownSeqDocument(:final header, :final error):
      return 'Not a recognized TestStand sequence.\n$header'
          '${error != null ? '\n\n$error' : ''}';
  }
}

/// A one-line title for a document (for the app bar / file label).
String documentTitle(SeqDocument doc) {
  final h = doc.header;
  final kind = switch (doc) {
    XmlSeqDocument(:final file) => '${file.sequences.length} sequences',
    BinarySeqDocument() => 'binary (recon)',
    UnknownSeqDocument() => 'unrecognized',
  };
  return '${h.fileType ?? 'TestStand'} · ${h.format.name} · $kind';
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
      if (l.leadingWords.isNotEmpty)
        ('Record header words', l.leadingWords.join(', ')),
    ],
  ];
}

/// A one-line label for model coverage, e.g. `model coverage 13.5% (1895/14016)`
/// — how much of the raw PropertyObject tree the typed lens accounts for. Pure.
String coverageLabel(SeqCoverage c) {
  final pct = (c.ratio * 100).toStringAsFixed(1);
  return 'model coverage $pct% (${c.modeled}/${c.total})';
}
