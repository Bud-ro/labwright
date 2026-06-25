/// Clean-room reader for NI TestStand sequence (`.seq`) and related files.
///
/// Status: **M0 (format reconnaissance).** The only decoded layer so far is the
/// file-header encoding sniffer ([detectSeqFormat] / [detectSeqHeader]); the
/// record grammars (XML element tree and the binary `TOF1` container) are the
/// next milestones. See `docs/teststand-viewer-spec.md` and the package
/// `NOTES.md`.
library;

export 'src/seq_format.dart';
