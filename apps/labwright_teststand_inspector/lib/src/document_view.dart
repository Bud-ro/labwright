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
