import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_binary_grammar.dart';
import 'seq_binary_model.dart';
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
        SeqFile? file;
        String? error;
        if (body != null) {
          try {
            file = parseBinarySeqFile(bytes, body: body);
          } on FormatException catch (e) {
            error = '$e';
          }
        }
        final pool = file?.binary;
        return BinarySeqDocument(
          header: detectSeqHeader(bytes),
          partialFile: file,
          inflatedSize: body?.length ?? 0,
          strings: pool != null ? _poolStrings(pool) : binaryStrings(body ?? Uint8List(0)),
          error: error,
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
    this.inflatedSize = 0,
    this.strings = const [],
    this.error,
  });

  @override
  final SeqFileHeader header;
  final SeqFile? partialFile;
  final int inflatedSize;

  final List<BinaryString> strings;

  /// Why the grammar did not apply, when [partialFile] is null.
  final String? error;
  List<String> get modulePaths => _where(isBinaryModulePath);
  List<String> get stepReferences => _where(_isStepRef);
  List<String> get expressions => _where(isBinaryExpression);
  List<String> get quotedLiterals => _where(isBinaryQuotedLiteral);

  List<String> _where(bool Function(String) keep) => {
    for (final s in strings)
      if (keep(s.text)) s.text,
  }.toList();
}

List<BinaryString> _poolStrings(Tof1Body body) {
  final out = <BinaryString>[];
  var offset = body.recordRegionLength + 4;
  for (final (i, entry) in body.poolEntries.indexed) {
    out.add((offset: offset, text: body.pool[i]));
    offset += entry.length + 1;
  }
  return out;
}

final _modulePathRe = RegExp(r'\.(vi|dll|seq|llb)$', caseSensitive: false);

bool isBinaryModulePath(String text) => text.contains('\\') && _modulePathRe.hasMatch(text);

bool _isStepRef(String text) => text.startsWith('ID#:');

final _exprRootRe = RegExp(r'\b(Locals|Parameters|Step|RunState|FileGlobals|StationGlobals|Seq|ThisContext)\.');

final _exprOpRe = RegExp(r'(==|!=|<=|>=|&&|\|\||\?.*:)');

final _exprFnRe = RegExp(r'\b(Abs|Str|Val|Round|Mid|Len|Left|Right|ResStr|LocalizeExpression|Mod)\s*\(');

bool isBinaryExpression(String text) =>
    !_isStepRef(text) &&
    !isBinaryModulePath(text) &&
    (_exprRootRe.hasMatch(text) || _exprOpRe.hasMatch(text) || _exprFnRe.hasMatch(text));

bool isBinaryQuotedLiteral(String text) =>
    text.length >= 2 && text.startsWith('"') && text.endsWith('"') && !isBinaryExpression(text);

class UnknownSeqDocument extends SeqDocument {
  const UnknownSeqDocument(this.header, {this.error});

  @override
  final SeqFileHeader header;
  final String? error;
}
