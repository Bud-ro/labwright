/// Clean-room reader for NI TestStand sequence (`.seq`) and related files.
///
/// Status: **M1 (XML decode).** Decoded so far:
/// - the file-header encoding sniffer ([detectSeqFormat] / [detectSeqHeader]);
/// - the **XML** encoding (via `package:xml`) into a faithful PropertyObject tree
///   ([parseSeqFile] → [SeqFile]) with a typed lens over [Sequence]s and [Step]s;
/// - the **XML writer** ([writeSeqFileXml]): byte-exact round-trip of every XML
///   corpus file (`write(parse(f)) == f`).
///
/// The binary `TOF1` encoding maps onto the same model and is the next milestone
/// ([parseSeqFile] throws for it rather than guessing). See
/// `docs/teststand-viewer-spec.md`.
///
/// Cross-flavor conversion ([iniToXmlSeqFile] / [xmlToIniSeqFile] /
/// [binaryToXmlSeqFile]) bridges the three encodings with 100% information
/// retention: INI → XML → INI and XML → INI → XML are corpus-gated
/// **byte-exact** (58/58 and 36/36), binary hops carry exactly the decoded
/// surface, explicitly marked partial. See `src/seq_convert.dart`.
library;

export 'src/dart_export.dart';
export 'src/seq_binary.dart';
export 'src/seq_convert.dart';
export 'src/seq_coverage.dart';
export 'src/seq_document.dart';
export 'src/seq_dump.dart';
export 'src/seq_equals.dart';
export 'src/seq_file.dart';
export 'src/seq_format.dart';
export 'src/seq_ini.dart';
export 'src/seq_module.dart';
export 'src/seq_property.dart';
export 'src/seq_step.dart';
export 'src/seq_typedefs.dart';
export 'src/seq_write_ini.dart';
export 'src/seq_write_xml.dart';
