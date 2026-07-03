import 'dart:typed_data';

import 'seq_binary.dart';
import 'seq_file.dart';
import 'seq_format.dart';

/// A parsed TestStand document — a single type a UI can switch on, regardless of
/// the on-disk encoding. XML files yield the full typed model; binary `TOF1`
/// files yield a recon view (header + recovered strings) since their record tree
/// isn't decoded yet; anything else yields [UnknownSeqDocument].
sealed class SeqDocument {
  const SeqDocument();

  /// The file header (encoding, file-type, product, version) — always present.
  SeqFileHeader get header;

  /// Parses [bytes] into the appropriate document kind. Total: never throws —
  /// an unparseable XML file degrades to [UnknownSeqDocument] with its header.
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
        final analysis = analyzeBinary(bytes);
        SeqFile? partial;
        try {
          partial = parseSeqFile(bytes);
        } on Exception {
          partial = null; // header-only / non-inflatable binary: recon only
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

/// A fully-decoded, [SeqFile]-backed document — the text encodings (XML and the
/// legacy INI) that map onto the typed PropertyObject model. UIs can switch on
/// this base to render the Dump/Sequences/Properties views regardless of which.
sealed class StructuredSeqDocument extends SeqDocument {
  const StructuredSeqDocument();

  /// The decoded sequence file (typed lens, dump, property tree).
  SeqFile get file;

  @override
  SeqFileHeader get header => file.header;
}

/// A fully-decoded XML sequence file.
class XmlSeqDocument extends StructuredSeqDocument {
  const XmlSeqDocument(this.file);

  @override
  final SeqFile file;
}

/// A fully-decoded legacy INI sequence file (same typed model as XML).
class IniSeqDocument extends StructuredSeqDocument {
  const IniSeqDocument(this.file);

  @override
  final SeqFile file;
}

/// A binary `TOF1` file: header decoded, body inflated, strings recovered, but
/// the record tree **not yet parsed** into the typed model.
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

  /// The **partial typed model** reconstructed from the decoded binary record
  /// structures — sequences with grouped, ordered step names (see
  /// [binarySequenceOutlines]). Sequence properties, variables, and step
  /// types/modules are not yet decoded, so those lenses read empty/null. Null
  /// when the body does not inflate.
  final SeqFile? partialFile;

  /// Size of the inflated body (0 if it could not be inflated).
  final int inflatedSize;

  /// All printable runs recovered from the inflated body (recon).
  final List<BinaryString> strings;

  /// The largest contiguous NUL-packed string table in the body (recon).
  final List<BinaryString> stringTable;

  /// The framed body layout (record region + string region), or null when the
  /// body did not frame. The record grammar itself is **not yet decoded**.
  final BinaryBodyLayout? layout;

  /// The content-identified **property-name table** (the packed string segment
  /// carrying the PropertyObject model tokens), or empty when none was found.
  /// Which other segments are value/expression tables is **not yet decoded**.
  final List<BinaryString> nameTable;

  /// The file's own **object names** beyond the fixed scaffold (recovered).
  final List<String> objectNames;

  /// **Module call-targets** the file invokes — VIs/DLLs/sub-sequences (recovered
  /// from the string pool; the record link to each step is **not yet decoded**).
  final List<String> modulePaths;

  /// `ID#:` **step references** the file carries (recovered; link not yet decoded).
  final List<String> stepReferences;

  /// **Expression** strings — the file's test logic (recovered; per-step
  /// attachment **not yet decoded**).
  final List<String> expressions;

  /// **Quoted string literals** — constant values (recovered; per-step
  /// attachment **not yet decoded**).
  final List<String> quotedLiterals;

  /// **Named-property scalar records** — inline doubles tied to their
  /// offset-referenced property name, carrying the raw (unmodeled) tag/type
  /// words. Genuinely decoded values + structural attribution.
  final List<BinaryNamedScalar> namedScalars;

  /// All distinct **inline numeric values** recovered from the record region —
  /// the superset of [namedScalars]' values (genuinely decoded; some not yet
  /// tied to a named record).
  final List<double> scalarDoubles;

  /// **Consistently-referenced named-property record headers** — which
  /// property/container names the records cite and how often, with the raw
  /// (unmodeled) consistent tag. The structural skeleton (header census, not a
  /// parse — record→step-tree links not yet decoded).
  final List<BinaryNamedRecord> namedRecords;
}

/// A file that is not a recognized/decodable TestStand sequence.
class UnknownSeqDocument extends SeqDocument {
  const UnknownSeqDocument(this.header, {this.error});

  @override
  final SeqFileHeader header;

  /// Why it couldn't be decoded (e.g. an XML parse error), if known.
  final String? error;
}
