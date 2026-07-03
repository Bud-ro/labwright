/// Clean-room reader for NI TestStand sequence (`.seq`) and related files.
///
/// Status: **M1 (XML decode).** Decoded so far:
/// - the file-header encoding sniffer ([detectSeqFormat] / [detectSeqHeader]);
/// - the **XML** encoding (via `package:xml`) into a faithful PropertyObject tree
///   ([parseSeqFile] → [SeqFile]) with a typed lens over [Sequence]s and [Step]s.
///
/// The binary `TOF1` encoding maps onto the same model and is the next milestone
/// ([parseSeqFile] throws for it rather than guessing). See
/// `docs/teststand-viewer-spec.md` and the package `NOTES.md`.
library;

export 'src/seq_binary.dart';
export 'src/seq_coverage.dart';
export 'src/seq_document.dart';
export 'src/seq_dump.dart';
export 'src/seq_file.dart';
export 'src/seq_format.dart';
export 'src/seq_ini.dart';
export 'src/seq_module.dart';
export 'src/seq_property.dart';
export 'src/seq_step.dart';
export 'src/seq_typedefs.dart';
