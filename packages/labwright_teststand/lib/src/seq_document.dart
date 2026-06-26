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
        return BinarySeqDocument(
          header: detectSeqHeader(bytes),
          inflatedSize: inflateBinaryBody(bytes)?.length ?? 0,
          strings: binaryBodyStrings(bytes),
          stringTable: binaryStringTable(bytes),
          layout: analyzeBinaryBody(bytes),
        );
      case SeqFormat.ini:
      case SeqFormat.unknown:
        return UnknownSeqDocument(detectSeqHeader(bytes));
    }
  }
}

/// A fully-decoded XML sequence file.
class XmlSeqDocument extends SeqDocument {
  const XmlSeqDocument(this.file);

  final SeqFile file;

  @override
  SeqFileHeader get header => file.header;
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
}

/// A file that is not a recognized/decodable TestStand sequence.
class UnknownSeqDocument extends SeqDocument {
  const UnknownSeqDocument(this.header, {this.error});

  @override
  final SeqFileHeader header;

  /// Why it couldn't be decoded (e.g. an XML parse error), if known.
  final String? error;
}
