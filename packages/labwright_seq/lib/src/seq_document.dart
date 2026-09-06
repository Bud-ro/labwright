import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_file.dart';
import 'seq_format.dart';

sealed class SeqDocument {
  const SeqDocument();

  SeqFileHeader get header;

  factory SeqDocument.parse(Uint8List bytes) {
    SeqDocument structured(StructuredSeqDocument Function(SeqFile) wrap) {
      try {
        return wrap(parseSeqFile(bytes));
      } catch (e) {
        return UnknownSeqDocument(detectSeqHeader(bytes), error: '$e');
      }
    }

    switch (detectSeqFormat(bytes)) {
      case SeqFormat.xml:
        return structured(XmlSeqDocument.new);
      case SeqFormat.binary:
        final body = inflateBinaryBody(bytes);
        final analysis = body == null ? null : analyzeBinary(bytes, body: body);
        SeqFile? partial;
        if (body != null) {
          try {
            partial = parseBinarySeqFile(bytes, body: body);
          } catch (_) {
            partial = null;
          }
        }
        return BinarySeqDocument(
          header: detectSeqHeader(bytes),
          partialFile: partial,
          inflatedSize: analysis?.inflatedSize ?? 0,
          strings: analysis?.strings ?? const [],
          stringTable: analysis?.stringTable ?? const [],
          layout: analysis?.layout,
          nameTable: analysis?.nameTable ?? const [],
          objectNames: analysis?.objectNames ?? const [],
          modulePaths: analysis?.modulePaths ?? const [],
          stepReferences: analysis?.stepReferences ?? const [],
          expressions: analysis?.expressions ?? const [],
          quotedLiterals: analysis?.quotedLiterals ?? const [],
          namedScalars: analysis?.namedScalars ?? const [],
          scalarDoubles: analysis?.scalarDoubles ?? const [],
          namedRecords: analysis?.namedRecords ?? const [],
        );
      case SeqFormat.ini:
        return structured(IniSeqDocument.new);
      case SeqFormat.unknown:
        return UnknownSeqDocument(detectSeqHeader(bytes));
    }
  }
}

sealed class StructuredSeqDocument extends SeqDocument {
  const StructuredSeqDocument();

  SeqFile get file;

  @override
  SeqFileHeader get header => file.header;
}

class XmlSeqDocument extends StructuredSeqDocument {
  const XmlSeqDocument(this.file);

  @override
  final SeqFile file;
}

class IniSeqDocument extends StructuredSeqDocument {
  const IniSeqDocument(this.file);

  @override
  final SeqFile file;
}

class BinarySeqDocument extends SeqDocument {
  const BinarySeqDocument({
    required this.header,
    this.partialFile,
    required this.inflatedSize,
    required this.strings,
    required this.stringTable,
    this.layout,
    this.nameTable = const [],
    this.objectNames = const [],
    this.modulePaths = const [],
    this.stepReferences = const [],
    this.expressions = const [],
    this.quotedLiterals = const [],
    this.namedScalars = const [],
    this.scalarDoubles = const [],
    this.namedRecords = const [],
  });

  @override
  final SeqFileHeader header;

  final SeqFile? partialFile;

  final int inflatedSize;

  final List<BinaryString> strings;

  final List<BinaryString> stringTable;

  final BinaryBodyLayout? layout;

  final List<BinaryString> nameTable;

  final List<String> objectNames;

  final List<String> modulePaths;

  final List<String> stepReferences;

  final List<String> expressions;

  final List<String> quotedLiterals;

  final List<BinaryNamedScalar> namedScalars;

  final List<double> scalarDoubles;

  final List<BinaryNamedRecord> namedRecords;
}

class UnknownSeqDocument extends SeqDocument {
  const UnknownSeqDocument(this.header, {this.error});

  @override
  final SeqFileHeader header;

  final String? error;
}
