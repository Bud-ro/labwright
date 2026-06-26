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
    switch (detectSeqFormat(bytes)) {
      case SeqFormat.xml:
        try {
          return XmlSeqDocument(parseSeqFile(bytes));
        } catch (e) {
          return UnknownSeqDocument(detectSeqHeader(bytes), error: '$e');
        }
      case SeqFormat.binary:
        // One inflate of the zlib body feeds every recon field (the individual
        // helpers would each re-inflate).
        final a = analyzeBinary(bytes);
        return BinarySeqDocument(
          header: detectSeqHeader(bytes),
          inflatedSize: a?.inflatedSize ?? 0,
          strings: a?.strings ?? const [],
          stringTable: a?.stringTable ?? const [],
          layout: a?.layout,
          nameTable: a?.nameTable ?? const [],
          objectNames: a?.objectNames ?? const [],
          modulePaths: a?.modulePaths ?? const [],
          stepReferences: a?.stepReferences ?? const [],
          expressions: a?.expressions ?? const [],
          quotedLiterals: a?.quotedLiterals ?? const [],
        );
      case SeqFormat.ini:
        // The legacy INI form maps onto the same typed model as XML — decode it
        // through the shared lens, degrading to a recon doc if it can't (e.g. the
        // rare file without a reconstructable %OBJROOT root).
        try {
          return IniSeqDocument(parseSeqFile(bytes));
        } catch (e) {
          return UnknownSeqDocument(detectSeqHeader(bytes), error: '$e');
        }
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
  });

  @override
  final SeqFileHeader header;

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
}

/// A file that is not a recognized/decodable TestStand sequence.
class UnknownSeqDocument extends SeqDocument {
  const UnknownSeqDocument(this.header, {this.error});

  @override
  final SeqFileHeader header;

  /// Why it couldn't be decoded (e.g. an XML parse error), if known.
  final String? error;
}
